#lang at-exp racket

(require (for-syntax syntax/parse) scribble/manual scribble/eval racket/sandbox)

(require racket/provide)

(provide 
 define-module-local-eval 
 provide-and-scribble all-from all-from-except
 )

;; ---------------------------------------------------------------------------------------------------

;; **********************************************************************************
;; this needs something like a @defmodule[localname] but perhaps
;; this should be added when I require the doc submodule
;; **********************************************************************************

(define-for-syntax *add #f)

(define-syntax-rule 
  (all-from a ...)
  (raise-syntax-error "use with provide-and-scribble only"))

(define-syntax-rule 
  (all-from-except a ...)
  (raise-syntax-error "use with provide-and-scribble only"))

(define-syntax (provide-and-scribble stx)
  (syntax-parse stx #:literals (defproc)
    [(provide-and-scribble doc-tag:id rows ...)
     (provide-and-scribble-proc #'doc-tag #'(rows ...))]))

(define-for-syntax (provide-and-scribble-proc doc-tag row*)
  (define-values (add-docs-and-provide provides)
    (for/fold ((add-docs-and-provide '()) (provides '())) ((row (syntax->list row*)))
      (syntax-parse row #:literals (defproc all-from all-from-except)
        [(all-from-except tag:id path label:id f:id ...)
         (define-values (a p) (provide-all-from #'path #'label #'tag #'(f ...)))
         (values (cons a add-docs-and-provide) (append (syntax->list p) provides))]
        [(all-from tag:id path label:id)
         (define-values (a p) (provide-all-from #'path #'label #'tag #'()))
         (values (cons a add-docs-and-provide) (append (syntax->list p) provides))]
        [(title (defproc (name args ...) range w ...) ...)
         (define name* (syntax->list #'(name ...)))
         (values (cons (lambda ()  ;; delay the syntax creation until add-sections is set
                         (with-syntax ([(ex ...) (extract-external-name name*)])
                           #`(#,*add title (list (cons #'ex (defproc (ex args ...) range w ...)) ...))))
                       add-docs-and-provide)
                 (cons #`(provide #,@(optional-rename-out name*))
                       provides))])))
  (provide-and-scribble-code doc-tag add-docs-and-provide provides))

;; Path Identifier Identifier [Listof Identifier] ->* [-> Syntax] Syntax[List]
;; create the require and provide clauses AND
;; delayed code for merging documentations from path -> label into the 'documentation' doc-tag submod
(define-for-syntax (provide-all-from path label prefix f*)
  (with-syntax ([path (syntax-case path (submod)
                        [(submod nested-path nested-tag) #'nested-path]
                        [_ path])]
                [(nested-tag ...)
                 (syntax-case path (submod)
                   [(submod nested-path nested-tag ...) #'(nested-tag ...)]
                   [_ #'()])]
                [label label]
                [prefix prefix]
                [(f ...) (syntax->list f*)]
                [mydocs (gensym 'mydocs)])
    (values (lambda ()  ;; delay the syntax creation until add-sections is set
	      ;; ******************************************************************
              ;; I was really hoping to make 
              ;;   (local-require (only-in (submod path nested-tag ... label) (docs mydocs)))
              ;; to work but that gave me problems about 'docs' already required before
              ;; so I went with dynamic-require. Argh. 
	      ;; ******************************************************************
              #`(for ((s ((dynamic-require '(submod path nested-tag ... label) 'docs) #'f ...)))
                  (#,*add (car s) (cadr s))))
            #`(;; import from path with prefix, exclude f ...
               (require (prefix-in prefix (except-in (submod path nested-tag ...) f ...)))
               ;; export the bindings without prefix 
               ; (local-require (only-in racket/provide filtered-out))
               (provide (filtered-out (lambda (name)
                                        (define prefix (format "^~a" (syntax-e #'prefix)))
                                        (and (regexp-match? prefix name)
                                             (regexp-replace prefix name "")))
                                      (all-from-out (submod path nested-tag ...))))))))

;; Identifier [Listof [-> Syntax]] [Listof Syntax] -> Syntax 
;; generate (module+ doc-tag ...) with the documentation in add-docs-and-provide, 
;; the first time it adds functions to (module+ doc-tag ...) that help render the docs
;; export the provides list 
(define-for-syntax (provide-and-scribble-code doc-tag add-docs-and-provide provides)
  (with-syntax ([(p* ...) provides])
    (cond 
      [*add #`(begin p* ... (module+ #,doc-tag #,@(map (lambda (adp) (adp)) add-docs-and-provide)))]
      [else
       (set! *add (syntax-local-introduce #'add-sections))
       #`(begin (module+ #,doc-tag 
                         ;; -----------------------------------------------------------------------
                         ;; Section  = [Listof (cons Identifier Doc)]
                         ;; Sections = [Listof (list Title Section)]
                         (provide 
                          ;; Identfier ... *-> Sections 
                          ;; retrieve the document without the specified identfiers
                          docs
                          
                          ;; Sections String -> [Listof ScribbleBox]
                          ;; render the sections as a scribble list of splice-boxes: #:tag-prefix p
                          render-sections)
                         ;; -----------------------------------------------------------------------
                         ;;
                         
                         (define (render-sections s c p)
                           (cond
                             [(null? s) '()]
                             [else 
                              (define section1 (car s))
                              (define others (render-sections (cdr s) c p))
                              (define-values (section-title stuff) (apply values section1))
                              (define sorted 
                                (sort stuff string<=? 
                                      #:key (lambda (x) (symbol->string (syntax-e (car x))))))
                              (define typed (for/list ((s sorted)) (re-context c (car s) (cdr s))))
                              (cons @section[#:tag-prefix p]{@section-title}
                                    (cons typed others))]))

			 ;; this is not going to work 
                         (define (re-context c id defproc)
                           defproc)
                         
                         ;;
                         (define (docs . exceptions)
                           (define s (reverse *sections))
                           (define (is-exception i)
                             (memf (lambda (j) (eq? (syntax-e j) (syntax-e i))) exceptions))
                           (for/fold ((result '())) ((s *sections))
                             (define sectn (second s))
                             (define clean 
                               (filter (lambda (i) (not (is-exception (car i)))) sectn))
                             (cons (list (first s) clean) result)))
                         ;; 
                         ;; state variable: Sections
                         (define *sections '())
                         ;; String Section -> Void 
                         ;; add _scontent_ section to *sections in the doc submodule 
                         (define (#,*add stitle scontent)
                           (define exists (assoc stitle *sections))
                           (if exists 
                               (set! *sections 
                                     (for/list ((s *sections))
                                       (if (string=? (first s) stitle)
                                           (list stitle (append scontent (second s)))
                                           s)))
                               (set! *sections (cons (list stitle scontent) *sections))))
                         
                         #,@(map (lambda (adp) (adp)) add-docs-and-provide))
                p* ...)])))

;; [Listof (u Identifier (Identifier Identifier))] -> [Listof Identifier]
(define-for-syntax (extract-external-name lon)
  (map (lambda (name-or-pair)
         (syntax-parse name-or-pair 
           [(internal:id external:id) #'external]
           [name:id #'name]))
       lon))

;; [Listof (u Identifier (Identifier Identifier))] -> [Listof Identifier]
;; create rename-out qualifications as needed
(define-for-syntax (optional-rename-out lon)
  (map (lambda (name-or-pair)
         (syntax-parse name-or-pair 
           [(internal:id external:id) #'(rename-out (internal external))]
           [name:id #'name]))
       lon))

;; ---------------------------------------------------------------------------------------------------

;; (define-module-local-eval name-of-evaluator)
;; a make-base-eval whose namespace is initialized with the module where the macro is used 
(define-syntax-rule 
  (define-module-local-eval name)
  (begin
    (define-namespace-anchor ns)
    (define name 
      (parameterize ([sandbox-namespace-specs (list (lambda () (namespace-anchor->namespace ns)))]
                     [sandbox-error-output 'string]
                     [sandbox-output 'string])
        (make-base-eval)))))