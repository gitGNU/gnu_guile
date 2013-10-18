;;; Continuation-passing style (CPS) intermediate language (IL)

;; Copyright (C) 2013 Free Software Foundation, Inc.

;;;; This library is free software; you can redistribute it and/or
;;;; modify it under the terms of the GNU Lesser General Public
;;;; License as published by the Free Software Foundation; either
;;;; version 3 of the License, or (at your option) any later version.
;;;;
;;;; This library is distributed in the hope that it will be useful,
;;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;;; Lesser General Public License for more details.
;;;;
;;;; You should have received a copy of the GNU Lesser General Public
;;;; License along with this library; if not, write to the Free Software
;;;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

;;; Commentary:
;;;
;;; Many passes rely on a local or global static analysis of a function.
;;; This module implements a simple data-flow graph (DFG) analysis,
;;; tracking the definitions and uses of variables and continuations.
;;; It also builds a table of continuations and scope links, to be able
;;; to easily determine if one continuation is in the scope of another,
;;; and to get to the expression inside a continuation.
;;;
;;; Note that the data-flow graph of continuation labels is a
;;; control-flow graph.
;;;
;;; We currently don't expose details of the DFG type outside this
;;; module, preferring to only expose accessors.  That may change in the
;;; future but it seems to work for now.
;;;
;;; Code:

(define-module (language cps dfg)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-26)
  #:use-module (language cps)
  #:export (build-cont-table
            build-local-cont-table
            lookup-cont

            compute-dfg
            dfg-cont-table
            lookup-def
            lookup-uses
            lookup-predecessors
            lookup-successors
            find-call
            call-expression
            find-expression
            find-defining-expression
            find-constant-value
            lift-definition!
            continuation-bound-in?
            variable-free-in?
            constant-needs-allocation?
            dead-after-def?
            dead-after-use?
            branch?
            find-other-branches
            dead-after-branch?
            lookup-bound-syms))

(define (build-cont-table fun)
  (fold-conts (lambda (k src cont table)
                (hashq-set! table k cont)
                table)
              (make-hash-table)
              fun))

(define (build-local-cont-table cont)
  (fold-local-conts (lambda (k src cont table)
                      (hashq-set! table k cont)
                      table)
                    (make-hash-table)
                    cont))

(define (lookup-cont sym conts)
  (let ((res (hashq-ref conts sym)))
    (unless res
      (error "Unknown continuation!" sym (hash-fold acons '() conts)))
    res))

;; Data-flow graph for CPS: both for values and continuations.
(define-record-type $dfg
  (make-dfg conts blocks use-maps)
  dfg?
  ;; hash table of sym -> $kif, $kargs, etc
  (conts dfg-cont-table)
  ;; hash table of sym -> $block
  (blocks dfg-blocks)
  ;; hash table of sym -> $use-map
  (use-maps dfg-use-maps))

(define-record-type $use-map
  (make-use-map sym def uses)
  use-map?
  (sym use-map-sym)
  (def use-map-def)
  (uses use-map-uses set-use-map-uses!))

(define-record-type $block
  (%make-block scope scope-level preds succs
               idom dom-level
               pdom pdom-level
               loop-header irreducible)
  block?
  (scope block-scope set-block-scope!)
  (scope-level block-scope-level set-block-scope-level!)
  (preds block-preds set-block-preds!)
  (succs block-succs set-block-succs!)
  (idom block-idom set-block-idom!)
  (dom-level block-dom-level set-block-dom-level!)

  (pdom block-pdom set-block-pdom!)
  (pdom-level block-pdom-level set-block-pdom-level!)

  ;; The loop header of this block, if this block is part of a reducible
  ;; loop.  Otherwise #f.
  (loop-header block-loop-header set-block-loop-header!)

  ;; Some sort of marker that this block is part of an irreducible
  ;; (multi-entry) loop.  Otherwise #f.
  (irreducible block-irreducible set-block-irreducible!))

(define (make-block scope scope-level)
  (%make-block scope scope-level '() '() #f #f #f #f #f #f))

(define (reverse-post-order k0 blocks accessor)
  (let ((order '())
        (visited? (make-hash-table)))
    (let visit ((k k0))
      (hashq-set! visited? k #t)
      (for-each (lambda (k)
                  (unless (hashq-ref visited? k)
                    (visit k)))
                (accessor (lookup-block k blocks)))
      (set! order (cons k order)))
    (list->vector order)))

(define (convert-predecessors order blocks accessor)
  (let* ((mapping (make-hash-table))
         (preds-vec (make-vector (vector-length order) #f)))
    (let lp ((n 0))
      (when (< n (vector-length order))
        (hashq-set! mapping (vector-ref order n) n)
        (lp (1+ n))))
    (let lp ((n 0))
      (when (< n (vector-length order))
        (let ((preds (accessor (lookup-block (vector-ref order n) blocks))))
          (vector-set! preds-vec n
                       ;; It's possible for a predecessor to not be in
                       ;; the mapping, if the predecessor is not
                       ;; reachable from the entry node.
                       (filter-map (cut hashq-ref mapping <>) preds))
          (lp (1+ n)))))
    preds-vec))

(define (compute-dom-levels idoms)
  (let ((dom-levels (make-vector (vector-length idoms) #f)))
    (define (compute-dom-level n)
      (or (vector-ref dom-levels n)
          (let ((dom-level (1+ (compute-dom-level (vector-ref idoms n)))))
            (vector-set! dom-levels n dom-level)
            dom-level)))
    (vector-set! dom-levels 0 0)
    (let lp ((n 0))
      (when (< n (vector-length idoms))
        (compute-dom-level n)
        (lp (1+ n))))
    dom-levels))

(define (compute-idoms preds)
  (let ((idoms (make-vector (vector-length preds) 0)))
    (define (common-idom d0 d1)
      ;; We exploit the fact that a reverse post-order is a topological
      ;; sort, and so the idom of a node is always numerically less than
      ;; the node itself.
      (cond
       ((= d0 d1) d0)
       ((< d0 d1) (common-idom d0 (vector-ref idoms d1)))
       (else (common-idom (vector-ref idoms d0) d1))))
    (define (compute-idom preds)
      (match preds
        (() 0)
        ((pred . preds)
         (let lp ((idom pred) (preds preds))
           (match preds
             (() idom)
             ((pred . preds)
              (lp (common-idom idom pred) preds)))))))
    ;; This is the iterative O(n^2) fixpoint algorithm, originally from
    ;; Allen and Cocke ("Graph-theoretic constructs for program flow
    ;; analysis", 1972).  See the discussion in Cooper, Harvey, and
    ;; Kennedy's "A Simple, Fast Dominance Algorithm", 2001.
    (let iterate ((n 0) (changed? #f))
      (cond
       ((< n (vector-length preds))
        (let ((idom (vector-ref idoms n))
              (idom* (compute-idom (vector-ref preds n))))
          (cond
           ((eqv? idom idom*)
            (iterate (1+ n) changed?))
           (else
            (vector-set! idoms n idom*)
            (iterate (1+ n) #t)))))
       (changed?
        (iterate 0 #f))
       (else idoms)))))

(define-inlinable (vector-push! vec idx val)
  (let ((v vec) (i idx))
    (vector-set! v i (cons val (vector-ref v i)))))

;; Compute a vector containing, for each node, a list of the nodes that
;; it immediately dominates.  These are the "D" edges in the DJ tree.
(define (compute-dom-edges idoms)
  (let ((doms (make-vector (vector-length idoms) '())))
    (let lp ((n 0))
      (when (< n (vector-length idoms))
        (let ((idom (vector-ref idoms n)))
          (vector-push! doms idom n))
        (lp (1+ n))))
    doms))

;; Compute a vector containing, for each node, a list of the successors
;; of that node that are not dominated by that node.  These are the "J"
;; edges in the DJ tree.
(define (compute-join-edges preds idoms)
  (define (dominates? n1 n2)
    (or (= n1 n2)
        (and (< n1 n2)
             (dominates? n1 (vector-ref idoms n2)))))
  (let ((joins (make-vector (vector-length idoms) '())))
    (let lp ((n 0))
      (when (< n (vector-length preds))
        (for-each (lambda (pred)
                    (unless (dominates? pred n)
                      (vector-push! joins pred n)))
                  (vector-ref preds n))
        (lp (1+ n))))
    joins))

;; Compute a vector containing, for each node, a list of the back edges
;; to that node.  If a node is not the entry of a reducible loop, that
;; list is empty.
(define (compute-reducible-back-edges joins idoms)
  (define (dominates? n1 n2)
    (or (= n1 n2)
        (and (< n1 n2)
             (dominates? n1 (vector-ref idoms n2)))))
  (let ((back-edges (make-vector (vector-length idoms) '())))
    (let lp ((n 0))
      (when (< n (vector-length joins))
        (for-each (lambda (succ)
                    (when (dominates? succ n)
                      (vector-push! back-edges succ n)))
                  (vector-ref joins n))
        (lp (1+ n))))
    back-edges))

;; Compute the levels in the dominator tree at which there are
;; irreducible loops, as an integer.  If a bit N is set in the integer,
;; that indicates that at level N in the dominator tree, there is at
;; least one irreducible loop.
(define (compute-irreducible-dom-levels doms joins idoms dom-levels)
  (define (dominates? n1 n2)
    (or (= n1 n2)
        (and (< n1 n2)
             (dominates? n1 (vector-ref idoms n2)))))
  (let ((pre-order (make-vector (vector-length doms) #f))
        (last-pre-order (make-vector (vector-length doms) #f))
        (res 0)
        (count 0))
    ;; Is MAYBE-PARENT an ancestor of N on the depth-first spanning tree
    ;; computed from the DJ graph?  See Havlak 1997, "Nesting of
    ;; Reducible and Irreducible Loops".
    (define (ancestor? a b)
      (let ((w (vector-ref pre-order a))
            (v (vector-ref pre-order b)))
        (and (<= w v)
             (<= v (vector-ref last-pre-order w)))))
    ;; Compute depth-first spanning tree of DJ graph.
    (define (recurse n)
      (unless (vector-ref pre-order n)
        (visit n)))
    (define (visit n)
      ;; Pre-order visitation index.
      (vector-set! pre-order n count)
      (set! count (1+ count))
      (for-each recurse (vector-ref doms n))
      (for-each recurse (vector-ref joins n))
      ;; Pre-order visitation index of last descendant.
      (vector-set! last-pre-order (vector-ref pre-order n) (1- count)))

    (visit 0)

    (let lp ((n 0))
      (when (< n (vector-length joins))
        (for-each (lambda (succ)
                    ;; If this join edge is not a loop back edge but it
                    ;; does go to an ancestor on the DFST of the DJ
                    ;; graph, then we have an irreducible loop.
                    (when (and (not (dominates? succ n))
                               (ancestor? succ n))
                      (set! res (logior (ash 1 (vector-ref dom-levels succ))))))
                  (vector-ref joins n))
        (lp (1+ n))))

    res))

(define (compute-nodes-by-level dom-levels)
  (let* ((max-level (let lp ((n 0) (max-level 0))
                      (if (< n (vector-length dom-levels))
                          (lp (1+ n) (max (vector-ref dom-levels n) max-level))
                          max-level)))
         (nodes-by-level (make-vector (1+ max-level) '())))
    (let lp ((n (1- (vector-length dom-levels))))
      (when (>= n 0)
        (vector-push! nodes-by-level (vector-ref dom-levels n) n)
        (lp (1- n))))
    nodes-by-level))

;; Collect all predecessors to the back-nodes that are strictly
;; dominated by the loop header, and mark them as belonging to the loop.
;; If they already have a loop header, that means they are either in a
;; nested loop, or they have already been visited already.
(define (mark-loop-body header back-nodes preds idoms loop-headers)
  (define (strictly-dominates? n1 n2)
    (and (< n1 n2)
         (let ((idom (vector-ref idoms n2)))
           (or (= n1 idom)
               (strictly-dominates? n1 idom)))))
  (define (visit node)
    (when (strictly-dominates? header node)
      (cond
       ((vector-ref loop-headers node) => visit)
       (else
        (vector-set! loop-headers node header)
        (for-each visit (vector-ref preds node))))))
  (for-each visit back-nodes))

(define (mark-irreducible-loops level idoms dom-levels loop-headers)
  ;; FIXME: Identify strongly-connected components that are >= LEVEL in
  ;; the dominator tree, and somehow mark them as irreducible.
  (warn 'irreducible-loops-at-level level))

;; "Identifying Loops Using DJ Graphs" by Sreedhar, Gao, and Lee, ACAPS
;; Technical Memo 98, 1995.
(define (identify-loops preds idoms dom-levels)
  (let* ((doms (compute-dom-edges idoms))
         (joins (compute-join-edges preds idoms))
         (back-edges (compute-reducible-back-edges joins idoms))
         (irreducible-levels
          (compute-irreducible-dom-levels doms joins idoms dom-levels))
         (loop-headers (make-vector (vector-length preds) #f))
         (nodes-by-level (compute-nodes-by-level dom-levels)))
    (let lp ((level (1- (vector-length nodes-by-level))))
      (when (>= level 0)
        (for-each (lambda (n)
                    (let ((edges (vector-ref back-edges n)))
                      (unless (null? edges)
                        (mark-loop-body n edges preds idoms loop-headers))))
                  (vector-ref nodes-by-level level))
        (when (logbit? level irreducible-levels)
          (mark-irreducible-loops level idoms dom-levels loop-headers))
        (lp (1- level))))
    loop-headers))

(define (analyze-control-flow! kentry kexit blocks)
  ;; First go forward in the graph, computing dominators and loop
  ;; information.
  (let* ((order (reverse-post-order kentry blocks block-succs))
         (preds (convert-predecessors order blocks block-preds))
         (idoms (compute-idoms preds))
         (dom-levels (compute-dom-levels idoms))
         (loop-headers (identify-loops preds idoms dom-levels)))
    (let lp ((n 0))
      (when (< n (vector-length order))
        (let* ((k (vector-ref order n))
               (idom (vector-ref idoms n))
               (dom-level (vector-ref dom-levels n))
               (loop-header (vector-ref loop-headers n))
               (b (lookup-block k blocks)))
          (set-block-idom! b (vector-ref order idom))
          (set-block-dom-level! b dom-level)
          (set-block-loop-header! b (and loop-header
                                         (vector-ref order loop-header)))
          (lp (1+ n))))))
  ;; Then go backwards, computing post-dominators.
  (let* ((order (reverse-post-order kexit blocks block-preds))
         (preds (convert-predecessors order blocks block-succs))
         (idoms (compute-idoms preds))
         (dom-levels (compute-dom-levels idoms)))
    (let lp ((n 0))
      (when (< n (vector-length order))
        (let* ((k (vector-ref order n))
               (pdom (vector-ref idoms n))
               (pdom-level (vector-ref dom-levels n))
               (b (lookup-block k blocks)))
          (set-block-pdom! b (vector-ref order pdom))
          (set-block-pdom-level! b pdom-level)
          (lp (1+ n)))))))

(define (visit-fun fun conts blocks use-maps global?)
  (define (add-def! sym def-k)
    (unless def-k
      (error "Term outside labelled continuation?"))
    (hashq-set! use-maps sym (make-use-map sym def-k '())))

  (define (add-use! sym use-k)
    (match (hashq-ref use-maps sym)
      (#f (error "Symbol out of scope?" sym))
      ((and use-map ($ $use-map sym def uses))
       (set-use-map-uses! use-map (cons use-k uses)))))

  (define* (declare-block! label cont parent
                           #:optional (level
                                       (1+ (lookup-scope-level parent blocks))))
    (hashq-set! conts label cont)
    (hashq-set! blocks label (make-block parent level)))

  (define (link-blocks! pred succ)
    (let ((pred-block (hashq-ref blocks pred))
          (succ-block (hashq-ref blocks succ)))
      (unless (and pred-block succ-block)
        (error "internal error"))
      (set-block-succs! pred-block (cons succ (block-succs pred-block)))
      (set-block-preds! succ-block (cons pred (block-preds succ-block)))))

  (define (visit exp exp-k)
    (define (def! sym)
      (add-def! sym exp-k))
    (define (use! sym)
      (add-use! sym exp-k))
    (define (use-k! k)
      (link-blocks! exp-k k))
    (define (recur exp)
      (visit exp exp-k))
    (match exp
      (($ $letk (($ $cont k src cont) ...) body)
       ;; Set up recursive environment before visiting cont bodies.
       (for-each (lambda (cont k)
                   (declare-block! k cont exp-k))
                 cont k)
       (for-each visit cont k)
       (recur body))

      (($ $kargs names syms body)
       (for-each def! syms)
       (recur body))

      (($ $kif kt kf)
       (use-k! kt)
       (use-k! kf))

      (($ $ktrunc arity k)
       (use-k! k))

      (($ $letrec names syms funs body)
       (unless global?
         (error "$letrec should not be present when building a local DFG"))
       (for-each def! syms)
       (for-each (cut visit-fun <> conts blocks use-maps global?) funs)
       (visit body exp-k))

      (($ $continue k exp)
       (use-k! k)
       (match exp
         (($ $var sym)
          (use! sym))

         (($ $call proc args)
          (use! proc)
          (for-each use! args))

         (($ $primcall name args)
          (for-each use! args))

         (($ $values args)
          (for-each use! args))

         (($ $prompt escape? tag handler)
          (use! tag)
          (use-k! handler))

         (($ $fun)
          (when global?
            (visit-fun exp conts blocks use-maps global?)))

         (_ #f)))))

  (match fun
    (($ $fun meta free
        ($ $cont kentry src
           (and entry
                ($ $kentry self ($ $cont ktail _ tail) clauses))))
     (declare-block! kentry entry #f 0)
     (add-def! self kentry)

     (declare-block! ktail tail kentry)

     (for-each
      (match-lambda
       (($ $cont kclause _
           (and clause ($ $kclause arity ($ $cont kbody _ body))))
        (declare-block! kclause clause kentry)
        (link-blocks! kentry kclause)

        (declare-block! kbody body kclause)
        (link-blocks! kclause kbody)

        (visit body kbody)))
      clauses)

     (analyze-control-flow! kentry ktail blocks))))

(define* (compute-dfg fun #:key (global? #t))
  (let* ((conts (make-hash-table))
         (blocks (make-hash-table))
         (use-maps (make-hash-table)))
    (visit-fun fun conts blocks use-maps global?)
    (make-dfg conts blocks use-maps)))

(define (lookup-block k blocks)
  (let ((res (hashq-ref blocks k)))
    (unless res
      (error "Unknown continuation!" k (hash-fold acons '() blocks)))
    res))

(define (lookup-scope-level k blocks)
  (match (lookup-block k blocks)
    (($ $block _ scope-level) scope-level)))

(define (lookup-use-map sym use-maps)
  (let ((res (hashq-ref use-maps sym)))
    (unless res
      (error "Unknown lexical!" sym (hash-fold acons '() use-maps)))
    res))

(define (lookup-def sym dfg)
  (match dfg
    (($ $dfg conts blocks use-maps)
     (match (lookup-use-map sym use-maps)
       (($ $use-map sym def uses)
        def)))))

(define (lookup-uses sym dfg)
  (match dfg
    (($ $dfg conts blocks use-maps)
     (match (lookup-use-map sym use-maps)
       (($ $use-map sym def uses)
        uses)))))

(define (lookup-predecessors k dfg)
  (match (lookup-block k (dfg-blocks dfg))
    (($ $block _ _ preds succs) preds)))

(define (lookup-successors k dfg)
  (match (lookup-block k (dfg-blocks dfg))
    (($ $block _ _ preds succs) succs)))

(define (find-defining-term sym dfg)
  (match (lookup-predecessors (lookup-def sym dfg) dfg)
    ((def-exp-k)
     (lookup-cont def-exp-k (dfg-cont-table dfg)))
    (else #f)))

(define (find-call term)
  (match term
    (($ $kargs names syms body) (find-call body))
    (($ $letk conts body) (find-call body))
    (($ $letrec names syms funs body) (find-call body))
    (($ $continue) term)))

(define (call-expression call)
  (match call
    (($ $continue k exp) exp)))

(define (find-expression term)
  (call-expression (find-call term)))

(define (find-defining-expression sym dfg)
  (match (find-defining-term sym dfg)
    (#f #f)
    (($ $ktrunc) #f)
    (($ $kclause) #f)
    (term (find-expression term))))

(define (find-constant-value sym dfg)
  (match (find-defining-expression sym dfg)
    (($ $const val)
     (values #t val))
    (($ $continue k ($ $void))
     (values #t *unspecified*))
    (else
     (values #f #f))))

(define (constant-needs-allocation? sym val dfg)
  (define (find-exp term)
    (match term
      (($ $kargs names syms body) (find-exp body))
      (($ $letk conts body) (find-exp body))
      (else term)))
  (match dfg
    (($ $dfg conts blocks use-maps)
     (match (lookup-use-map sym use-maps)
       (($ $use-map _ def uses)
        (or-map
         (lambda (use)
           (match (find-expression (lookup-cont use conts))
             (($ $call) #f)
             (($ $values) #f)
             (($ $primcall 'free-ref (closure slot))
              (not (eq? sym slot)))
             (($ $primcall 'free-set! (closure slot value))
              (not (eq? sym slot)))
             (($ $primcall 'cache-current-module! (mod . _))
              (eq? sym mod))
             (($ $primcall 'cached-toplevel-box _)
              #f)
             (($ $primcall 'cached-module-box _)
              #f)
             (($ $primcall 'resolve (name bound?))
              (eq? sym name))
             (_ #t)))
         uses))))))

(define (continuation-scope-contains? scope-k k blocks)
  (let ((scope-level (lookup-scope-level scope-k blocks)))
    (let lp ((k k))
      (or (eq? scope-k k)
          (match (lookup-block k blocks)
            (($ $block scope level)
             (and (< scope-level level)
                  (lp scope))))))))

;; FIXME: Splice preds, succs, dom tree.
(define (lift-definition! k scope-k dfg)
  (match dfg
    (($ $dfg conts blocks use-maps)
     (let ((scope-level (1+ (lookup-scope-level scope-k blocks))))
       ;; Fix parent scope link of K.
       (match (lookup-block k blocks)
         ((and block ($ $block))
          (set-block-scope! block scope-k)))
       ;; Fix up scope levels of K and all contained scopes.
       (let update-levels! ((k k) (level scope-level))
         (match (lookup-block k blocks)
           ((and block ($ $block))
            (set-block-scope-level! block scope-level)))
         (let lp ((cont (lookup-cont k conts)))
           (match cont
             (($ $letk (($ $cont kid) ...) body)
              (for-each (cut update-levels! <> (1+ scope-level)) kid)
              (lp body))
             (($ $letrec names syms funs body)
              (lp body))
             (_ #t))))))))

(define (continuation-bound-in? k use-k dfg)
  (match dfg
    (($ $dfg conts blocks use-maps)
     (match (lookup-block k blocks)
       (($ $block def-k)
        (continuation-scope-contains? def-k use-k blocks))))))

(define (variable-free-in? var k dfg)
  (match dfg
    (($ $dfg conts blocks use-maps)
     (or-map (lambda (use)
               (continuation-scope-contains? k use blocks))
             (match (lookup-use-map var use-maps)
               (($ $use-map sym def uses)
                uses))))))

;; Does k1 dominate k2?
(define (dominates? k1 k2 blocks)
  (let ((b1 (lookup-block k1 blocks))
        (b2 (lookup-block k2 blocks)))
    (let ((k1-level (block-dom-level b1))
          (k2-level (block-dom-level b2)))
      (cond
       ((> k1-level k2-level) #f)
       ((< k1-level k2-level) (dominates? k1 (block-idom b2) blocks))
       ((= k1-level k2-level) (eqv? k1 k2))))))

;; Does k1 post-dominate k2?
(define (post-dominates? k1 k2 blocks)
  (let ((b1 (lookup-block k1 blocks))
        (b2 (lookup-block k2 blocks)))
    (let ((k1-level (block-pdom-level b1))
          (k2-level (block-pdom-level b2)))
      (cond
       ((> k1-level k2-level) #f)
       ((< k1-level k2-level) (post-dominates? k1 (block-pdom b2) blocks))
       ((= k1-level k2-level) (eqv? k1 k2))))))

(define (dead-after-def? sym dfg)
  (match dfg
    (($ $dfg conts blocks use-maps)
     (match (lookup-use-map sym use-maps)
       (($ $use-map sym def uses)
        (null? uses))))))

(define (lookup-loop-header k blocks)
  (block-loop-header (lookup-block k blocks)))

(define (dead-after-use? sym use-k dfg)
  (match dfg
    (($ $dfg conts blocks use-maps)
     (match (lookup-use-map sym use-maps)
       (($ $use-map sym def uses)
        ;; If all other uses dominate this use, and the variable was not
        ;; defined outside the current loop, it is now dead.  There are
        ;; other ways for it to be dead, but this is an approximation.
        ;; A better check would be if all successors post-dominate all
        ;; uses.
        (and (let ((loop (lookup-loop-header use-k blocks)))
               (or (eqv? def loop)
                   (eqv? (lookup-loop-header def blocks) loop)))
             (and-map (cut dominates? <> use-k blocks) uses)))))))

;; A continuation is a "branch" if all of its predecessors are $kif
;; continuations.
(define (branch? k dfg)
  (let ((preds (lookup-predecessors k dfg)))
    (and (not (null? preds))
         (and-map (lambda (k)
                    (match (lookup-cont k (dfg-cont-table dfg))
                      (($ $kif) #t)
                      (_ #f)))
                  preds))))

(define (find-other-branches k dfg)
  (map (lambda (kif)
         (match (lookup-cont kif (dfg-cont-table dfg))
           (($ $kif (? (cut eq? <> k)) kf)
            kf)
           (($ $kif kt (? (cut eq? <> k)))
            kt)
           (_ (error "Not all predecessors are branches"))))
       (lookup-predecessors k dfg)))

(define (dead-after-branch? sym branch other-branches dfg)
  (match dfg
    (($ $dfg conts blocks use-maps)
     (match (lookup-use-map sym use-maps)
       (($ $use-map sym def uses)
        ;; As in dead-after-use?, we don't kill the variable if it was
        ;; defined outside the current loop.
        (and (let ((loop (lookup-loop-header branch blocks)))
               (or (eqv? def loop)
                   (eqv? (lookup-loop-header def blocks) loop)))
             (and-map
              (lambda (use-k)
                ;; A symbol is dead after a branch if at least one of the
                ;; other branches dominates a use of the symbol, and all
                ;; other uses of the symbol dominate the test.
                (if (or-map (cut dominates? <> use-k blocks)
                            other-branches)
                    (not (dominates? branch use-k blocks))
                    (dominates? use-k branch blocks)))
              uses)))))))

(define (lookup-bound-syms k dfg)
  (match dfg
    (($ $dfg conts blocks use-maps)
     (match (lookup-cont k conts)
       (($ $kargs names syms body)
        syms)))))