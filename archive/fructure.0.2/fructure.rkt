#lang racket

(require
  lens/common
  lens/data/list
  racket/gui/base
  fancy-app
  "fructure-style-ast.rkt"
  "fructure-language.rkt"
  "fructure-utility.rkt")

(require
  (for-syntax racket/match
              racket/list
              racket/syntax
              racket/function
              "fructure-language.rkt"
              "fructure-utility.rkt"))

; ----------------------------------------------------------------------------


(require (rename-in racket (#%app call)))
(define-syntax #%app
  (syntax-rules (⋱↦ ↦ ↓ ≡)
    [[#%app pattern ≡]
     (match-lambda
       [pattern #true]
       [_ #false])]
    [[#%app pattern ↦ result]
     (match-lambda
       [`pattern `result]
       [x x])]
    [[#%app pattern ⋱↦ result]
     (#%app [pattern ⋱↦ result])]
    [(#%app [pattern ⋱↦ result] ...)
     (letrec ([transform (match-lambda
                           [`pattern `result] ...
                           [(? atom? a) a]
                           [(? list? ls) (map transform ls)])])
       transform)]
    [(#%app f-expr arg-expr ...) (call f-expr arg-expr ...)]))



(define-match-expander reg
  (λ (stx)
    (syntax-case stx ()
      [(_ <str>) #'(? char? (app string (regexp <str>)))])))

; ----------------------------------------------------------------------------



(begin-for-syntax
 
  ; rewrites a form signature into a pattern-template pair for the parser
  (define (make-parse-pair pattern)
    (match pattern
      [(? form-name?)
       `(,pattern ,pattern)]
      [(? sort-name?)
       `(,(// (gensym)) ,pattern)]
      [`(ooo ,(app make-parse-pair `(,new-pat ,new-temp)))
       `((ooo ,new-pat) ,(/@ `(make-list (length ,(\\ (if (equal? 'unquote (first new-pat)) new-pat (first new-pat)))) ,(\\ new-temp))))]
      ; the above is sort of a hack. the test for first not equalling unquote detects when new-pat is actually a list of pats
      ; but maybe not robustly? to clarify, when the first is unquote we're assuming it's just a quoted, unquoted variable name
      [(? list? ls)
       (transpose (map make-parse-pair ls))]))

  
  ; maps in the ignore-affo pattern to stop in-line afforfances from interferring with parsing
  (define (add-ignores source)
    (match source
      ['... '...]
      [(list 'unquote x) source]
      [(? symbol?) (// `(ignore-affo ,source))]
      [(? list?) (// `(ignore-affo ,(map add-ignores source)))]))


  ; rewrites form signatures into pattern-template pair for the parser
  (define form-list->parse-pair
    (compose (match-lambda [`(,(app add-ignores pat) ,tem) `(,pat ,tem)])
             (curry map-rec redotdotdot)
             make-parse-pair
             (curry map-rec undotdotdot)
             #; (match-lambda [(? list?) make-parse-pair]
                              [(? sort-name? (app (λ (sort-name) (??? sort-name ???))))])
             ))


  ; rewrites the forms of a language specification into parse-pairs 
  (define lang->parse-lang
    (match-lambda
      [`((,sort-name (|| ,form ...)) ...)
       (transpose `(,sort-name ,(map (curry map form-list->parse-pair) form)))])))



; changes a pattern into one that ignores over-wrapped affordances
(define-match-expander ignore-affo
  (syntax-rules ()
    [(ignore-affo <pat>)
     (app (λ (source) (match source
                        #; [`((,(? affo-name?) ,(and a (? affo-name?))) ,x ,y) `(,a ,x ,y)]
                        [`(,(? affo-name?) ,buf ,a) (match a
                                                      [`(,(? affo-name?) ,b) b]
                                                      [`(,(? affo-name?) ,buf ,b) b]
                                                      [_ a])]
                        [`(,(? affo-name?) ,a) (match a
                                                 [`(,(? affo-name?) ,b) b]
                                                 [`(,(? affo-name?) ,buf ,b) b]
                                                 [_ a])]
                        ; the above is a hack. how do i recurse right in macros
                        [_ source])) `<pat>)]))


; matches source to a form from the provided list 
(define-syntax (source+grammar->form stx)
  (syntax-case stx ()
    [(_ <sort> <source> <language>)  
     (let ([proc-lang (lang->parse-lang (eval (syntax->datum #'<language>)))])
       (with-syntax* ([((<sort-name> ((<new-pat> <new-tem>) ...)) ...) (datum->syntax #'<source> proc-lang)])
         #'(match <sort>
             ['<sort-name>
              (match <source>
                [`<new-pat> `<new-tem>] ...
                [(? atom? a) a])]
             ...)))]))


; actually plug in language (L1)
(define (source->form sort source)
  (source+grammar->form
   sort
   source
   L1))





; helpers for parsing ---------------------------------------------------

(define (sel◇ source) `(◇ ,source))

(define/match (◇-project source)
  [(`(◇ ,a)) a]
  [((? atom? a)) #f]
  [(_) (let ([result (filter-map ◇-project source)])
         (if (empty? result) #f (first result)))])


(define (lens-ith-child i fn source)
  (lens-transform (list-ref-lens i) source fn))


(define (◇-ith-child i)
  [(◇ (,ls ...))
   ⋱↦ ,(lens-ith-child i sel◇ ls)])


(define (->child-contexts parent-context src)
  (map (λ (i) ((◇-ith-child i) parent-context)) (range (length src))))


(define/match ((fmap-fruct fn) source)
  [(_ (? atom?)) (fn source)]
  [(_ (? list?)) (map (curry fmap-fruct fn) source)])


(define ((lookup-style-in styles) property)
  (second (assoc property styles)))


(define (fill-in-parent-refs parent-styles)
  [(,property (parent ,parent-prop))
   ⋱↦ (,property ,((lookup-style-in parent-styles) parent-prop))])


(define (cascade-styles parent-styles)
  (match-lambda
    [(and hs (hash-table ('style styles)))
     (hash-set hs 'style ((fill-in-parent-refs parent-styles) styles))]
    [`(,(and hs (hash-table ('style (app (fill-in-parent-refs parent-styles) new-parent-styles)))) ,xs ...)
     `(,(hash-set hs 'style new-parent-styles) ,@(map (cascade-styles new-parent-styles) xs))]))


#; '(fmap:fruct->fruct [(:in <in-pair> ...)
                        (:out <out-pair> ...)] ...)
#; '(curry fmap-fruct (match-lambda
                        [(hash-table <in-pair> ...)
                         (hash-set source <out-pair> ...)])) ; need to splice outpairs


; languages as interfaces


; parsing ------------------------------------------------------


; map an s-expression to a fructure-ast.
(define (sexp->fruct source [ctx `(top (◇ expr))])
  (match source
    ; special case for single-hole affordances
    [`(,(? affo-name? affo) ,sel) 
     `(,(hash 'symbol void
              'self `(◇ (,affo hole))
              'sort 'affo
              'context '())
       ,(hash 'symbol affo
              'self `((◇ ,affo) hole)
              'context '())
       ,(sexp->fruct sel ctx))]
    ; special case for bind/muq affordance
    [`(⋈ ,name ,sel)
     `(,(hash 'symbol void
              'self `(◇ (⋈ name hole))
              'sort 'affo
              'context '()) 
       ,(hash 'symbol '⋈
              'self `((◇ ⋈) name hole)
              'context '())
       ,(sexp->fruct name `(⋈ (◇ name) hole))
       ,(sexp->fruct sel ctx))]
    ; special case for double-hole affordances    
    [`(,(? affo-name? affo) ,buf ,sel)
     `(,(hash 'symbol void
              'self `(◇ (,affo hole hole))
              'sort 'affo
              'context '()) 
       ,(hash 'symbol affo
              'self `((◇ ,affo) hole hole)
              'context '())
       ,(sexp->fruct buf ctx)
       ,(sexp->fruct sel ctx))]
    [_
     (match (◇-project ctx)
       [(? terminal-name?)
        (hash 'symbol source
              'self ctx
              'sort source 
              'context ctx)]
       [(? form-name?)
        (hash 'symbol source
              'self ctx
              'sort 'literal-symbol
              'context ctx)]
       [(? sort-name? sort)
        (let* ([form (source->form sort source)]
               [hash (hash 'symbol (if (list? form) void source)
                           'self `(◇ ,form)
                           'sort sort
                           'context ctx)])
          (if (list? form)
              `(,hash ,@(map sexp->fruct source (->child-contexts `(◇ ,form) source)))
              hash))]
       [(? list?)
        `(,(hash 'symbol void
                 'self ctx
                 'sort 'literal-list
                 'context ctx) ,@(map sexp->fruct source (->child-contexts ctx source)))])]))


; add racket-gui objects to a fructure-ast
(define ((fruct->fruct+gui parent-ed) source)
  (let* ([ed (new fruct-ed%)]
         [sn (new fruct-sn% [editor ed] [parent-editor parent-ed])]
         [gui (gui sn ed parent-ed)])
    (match source
      [`(,hs ,xs ...) `(,(hash-set hs 'gui gui) ,@(map (fruct->fruct+gui ed) xs))]
      [(hash-table) (hash-set source 'gui gui)])))


; returns a fn which takes an sexpr and returns a fully parsed version
; AND actually imperatively creates the GUI 
(define (make-gui parent-ed)
  (compose (fmap-fruct (match-lambda
                         [(and hs (hash-table ('symbol s) ('gui (gui _ ed _))))
                          (when (not (equal? s void))
                            (send ed insert (cond [(symbol? s) (symbol->string s)]
                                                  [else (~a s)]))) hs]))
           (fmap-fruct (match-lambda
                         [(and hs (hash-table ('style st) ('gui g)))
                          (apply-style! st g) hs]))
           ; include symbol as arg to above apply-style and do insert symbol as part of apply-style
           ; abstract this imperative part out of this (so make-gui is pure; rename?)
           ; move imperative part to update-gui below?
           (fmap-fruct (match-lambda
                         [(and hs (hash-table ('symbol s) ('gui (gui sn _ parent-ed))))
                          (send parent-ed insert sn) hs]))
           ; like make this insert part of style as well? like, if 'show' is true, do insert
           ; otherwise just insert some placeholder affordance instead?
           (cascade-styles '((format horizontal)
                             (background-color (color 150 255 150))
                             (text-color (color 128 128 128))
                             (border-style none)
                             (border-color (color 150 255 150))
                             (visible #true)))
           (fmap-fruct (match-lambda
                         [(and hs (hash-table ('self s)))
                          (hash-set hs 'style (lookup-style s))]))
           (fruct->fruct+gui parent-ed)
           sexp->fruct))



; machish principle:
; grammar here is effected by structure there
; ie or eg scope


; gui objs & structs ------------------------------------

#; (struct gui (sn ed parent-ed)) ; this is now in stylefile

(define fruct-board%
  (class pasteboard% 
    (define/override (on-default-char event)
      (char-input event))
    (super-new)))


(define fruct-ed%
  (class text% (super-new [line-spacing 0])
    
    #; (define/public (set-text-color color)
         ;must be after super so style field is intialized
         (define my-style-delta (make-object style-delta%))

         (send my-style-delta set-size-add 14)
      
         #; (send my-style-delta set-delta-background color) ; text bkg
         #; (send my-style-delta set-alignment-on 'top) ; ???
         #; (send my-style-delta set-transparent-text-backing-on #f) ; ineffective
      
         (match color
           [`(color ,r ,g ,b)
            (send my-style-delta set-delta-foreground (make-color r g b))])
      
         (send this change-style my-style-delta))

    (define/public (set-text-style color size family align italic? bold? smooth?)
                  
      (define my-style-delta (make-object style-delta%))

      (send my-style-delta set-delta-foreground (apply make-color (rest color)))
      (send my-style-delta set-delta 'change-size size)
      (send my-style-delta set-delta 'change-family family)
      (send my-style-delta set-delta 'change-alignment align)
      (send my-style-delta set-delta 'change-style (if italic? 'italic 'normal))
      (send my-style-delta set-delta 'change-weight (if bold? 'bold 'normal))
      (send my-style-delta set-delta 'change-smoothing (if smooth? 'smoothed 'unsmoothed))
      
      (send this change-style my-style-delta))
    
    (define/public (set-format format)
      (match format
        ['horizontal (format-horizontal)]
        ['vertical (format-vertical)]
        ['indent (format-indent-after 2)]
        [`(indent-after ,n) (format-indent-after n)]))

    (define/public (set-string-form string)
      (remove-text-snips)
      (send this insert string))
         
    (define (remove-text-snips)
      (for ([pos (range 0 (send this last-position))])
        (when (is-a? (send this find-snip pos 'before) string-snip%)
          (send this release-snip (send this find-snip pos 'before))
          (remove-text-snips))))

    (define (format-horizontal)
      (remove-text-snips))
                    
    (define (format-vertical)
      (remove-text-snips)
      (let ([num-items (send this last-position)])
        (for ([pos (range 1 (- (* 2 num-items) 2) 2)])
          (send this insert "\n" pos))))

    
    ; todo: update this to take variable number of spaces
    (define (format-indent-after start-at)
      (remove-text-snips)
      (let ([num-items (send this last-position)])
        (for ([pos (range start-at (* 2 (sub1 num-items)) 2)])
          (send this insert "\n" pos))
        (for ([line-num (range 1 (add1 (- num-items start-at)))])
          (send this insert "    " (send this line-start-position line-num)))))

    (define/override (on-default-char event)
      (char-input event))))


(define fruct-sn%
  (class editor-snip% (super-new [with-border? #f])
                    
    (init-field parent-editor)
    
    (field [background-color (make-color 28 28 28)]) ; current default
    (field [border-color (make-color 0 255 0)])
    (field [border-style 'none])
    
    (define/public (set-background-color color)
      (match color
        [`(color ,r ,g ,b)
         (set! background-color (make-color r g b))]))
    
    (define/public (set-border-color color)
      (match color
        [`(color ,r ,g ,b)
         (set! border-color (make-color r g b))]))
    
    (define/public (set-border-style style)
      (set! border-style style))

    (define/public (set-margins l t r b)
      #; (send this set-inset 0 0 0 0)
      #; (send this set-align-top-line #t) ; ???
      (send this set-margin l t r b))

    
    (define/override (draw dc x y left top right bottom dx dy draw-caret)
 
      #; (send dc set-text-mode 'transparent) ; ineffective
      #; (send dc set-background "blue") ; ineffective
      #; (send editor get-extent width height) ; try this instead?

      #; (define bottom-x (box 2))
      #; (define bottom-y (box 2))
      #; (send parent-editor get-snip-location this bottom-x bottom-y #t)
      #; (send dc draw-rectangle (+ x 0) (+ y 0) (+ (unbox bottom-x) 0) (+ (unbox bottom-y) 0))

      
      (define-values (a-w a-h a-descent a-space a-lspace a-rspace)
        (values (box 0) (box 0) (box 0) (box 0) (box 0) (box 0) ))
 
      (send this get-extent dc x y a-w a-h a-descent a-space a-lspace a-rspace)
      
      (define-values (left-x top-y right-x bot-y width height)
        (values x y (+ x (unbox a-w)) (+ y (unbox a-h)) (unbox a-w) (unbox a-h)))

      
      (define (draw-background color)
        (send this use-style-background #t) ; otherwise whiteness ensues
        (send dc set-brush color 'solid)
        (send dc set-pen color 1 'solid)
        (send dc draw-rectangle (+ x 0) (+ y 0) (+ width 0) (+ height 0)))

      (define (draw-left-square-bracket color)
        (send dc set-pen color 1 'solid)
        (send dc draw-line left-x top-y left-x (+ bot-y -1))
        (send dc draw-line left-x top-y (+ 2 left-x) top-y)
        (send dc draw-line left-x (+ bot-y -1) (+ 2 left-x) (+ bot-y -1)))

      (define (draw-right-square-bracket color)
        (send dc set-pen color 1 'solid)
        (send dc draw-line (+ -1 right-x) top-y (+ -1 right-x) (+ bot-y -1))
        (send dc draw-line right-x top-y (+ -2 right-x) top-y)
        (send dc draw-line right-x (+ bot-y -1) (+ -2 right-x) (+ bot-y -1)))

      (define (draw-full-box-border color)
        (send dc set-pen color 1 'solid)
        (send dc draw-line left-x top-y right-x top-y)
        (send dc draw-line left-x top-y left-x (+ bot-y -1))
        (send dc draw-line right-x top-y right-x (+ bot-y -1))
        (send dc draw-line left-x (+ bot-y -1) right-x (+ bot-y -1)))

      (define (draw-square-brackets color)
        (draw-left-square-bracket color)
        #;(draw-right-square-bracket color))
      
      (define (draw-both-square-brackets color)
        (draw-left-square-bracket color)
        (draw-right-square-bracket color))
      
      ; actual draw calls (order sensitive!) -------------------------
      
      (draw-background background-color)
      
      (case border-style
        ['none void]
        ['full-box (draw-full-box-border border-color)]
        ['square-brackets (draw-square-brackets border-color)]
        ['both-square-brackets (draw-both-square-brackets border-color)])

      (send dc set-pen (make-color 255 255 255) 1 'solid)
      (super draw dc x y left top right bottom dx dy draw-caret))))






; state processing ------------------------------------

(define (update-gui stage kit)
  (let* ([new-main-board (new fruct-board%)]
         [new-stage-board (new fruct-ed%)]
         [stage-board-snip (new fruct-sn% [editor new-stage-board] [parent-editor new-main-board])]
         #;[new-kit-board (new fruct-ed%)]
         #;[kit-snip (new fruct-sn% [editor new-kit-board] [parent-editor new-main-board])])

    (set! stage-gui ((make-gui new-stage-board) stage))
    
    (send new-main-board insert stage-board-snip)
    
    #;(set! kit-gui ((make-gui new-kit-board) kit))
    #;(send new-main-board insert kit-snip)
    
    #;(send new-main-board move-to stage-board-snip 200 0)
    
    (send my-canvas set-editor new-main-board)
    (send new-main-board set-caret-owner #f 'global)))



(define (!do fn)
  (set! stage (fn stage))
  (set! stage-gui ((make-gui (new fruct-ed%)) stage))
  (update-gui stage kit))



; transformation --------------------------------------


; notes: how to do relativize-direction right:
; should ideally depend only on style, no looking into gui-data like it does now
; find most immediate (grand)parent contained within a parent with non-horizontal formatting type
; the prev/next siblings are candidates for moving (in)to when we press up/down
; complications:
; 1. if there is no prev/next sibling, then we try the parent, and so-on recursively
; 2. if the formatting type is indent, or some other format with mixed horizontal and vertical formatting
; hack for now: assume only other type is indent-after. compare position to 'after' to decide
; whether up/down should apply to parent, or if we have to recurse upwards 




; helpers for main loop ------------------------------


(define simple-select
  [,a ⋱↦ (▹ ,a)])

(define simple-deselect
  [(▹ ,a) ⋱↦ ,a])


; returns a list of lenses into source whose views are pred?
(define/match ((?->lenses pred?) source)
  [(_ (? pred?)) `(,identity-lens)]
  [(_ (? atom?)) #f]
  [(_ (? list?)) (flatten (filter-map (λ (x i) (let ([res ((?->lenses pred?) x)])
                                                 (if res
                                                     (map (λ (y) (if y
                                                                     (lens-compose y (list-ref-lens i))
                                                                     #f))
                                                          res)
                                                     #f)))
                                      source
                                      (range (length source))))])


; true if there's a pred? in source
(define ((contains- pred?) source)
  (not (empty? ((?->lenses pred?) source))))


(define ▹▹->lenses
  (?->lenses [`(▹▹ ,a) ≡]))


(define (▹-first-▹▹-in source)
  (lens-transform (first (▹▹->lenses source)) source [(▹▹ ,a) ↦ (▹▹ (▹ ,a))]))


(define (▹-next-▹▹ source)
  (match (▹▹->lenses source)
    [`(,x ... ,(and a (app (curryr lens-view source) `(▹▹ (▹ ,w)))) ,b ,y ...)
     (lens-transform/list source
                          a [(▹▹ (▹ ,x)) ↦ (▹▹ ,x)]
                          b [(▹▹ ,x) ↦ (▹▹ (▹ ,x))])]
    [`(,b ,x ... ,(and a (app (curryr lens-view source) `(▹▹ (▹ ,w)))))
     (lens-transform/list source
                          a [(▹▹ (▹ ,x)) ↦ (▹▹ ,x)]
                          b [(▹▹ ,x) ↦ (▹▹ (▹ ,x))])]
    [_ source]))


#; (define (▹-next-▹▹ source)
     (match source
       [(ctx `(▹▹ ,a) ⋱ `(,x ... (▹ ,y) ,z ,w... ))
        (ctx ⋱ `(,@x ,y (▹ ,z) ,@w))]
       [(ctx `(▹▹ ,a) ⋱ `(,x ,y ... (▹ ,z)))
        (ctx ⋱ `((▹ ,x) ,@y z))]))
; note that pattern `(▹▹ ,a) is used to destructure each match


(define ((▹-first-?-in pred?) source)
  (lens-transform (first ((?->lenses [(? pred?) ≡]) source)) source [,a ↦ (▹ ,a)]))


(define ((▹-next-? pred?) source)
  (match ((?->lenses [(or (? pred?) `(▹ ,_)) ≡]) source)
    [`(,a ... ,(and b (app (curryr lens-view source) `(▹ ,x))) ,c ,ds ...)
     (lens-transform/list source
                          b [(▹ ,x) ↦ ,x]
                          c [,x ↦ (▹ ,x)])]
    [`(,a ,bs ... ,(and c (app (curryr lens-view source) `(▹ ,x))))
     (lens-transform/list source
                          c [(▹ ,x) ↦ ,x]
                          a [,x ↦ (▹ ,x)])]
    [_ source]))


(define ((▹-prev-? pred?) source)
  (match ((?->lenses [(or (? pred?) `(▹ ,_)) ≡]) source)
    [`(,as ... ,b ,(and c (app (curryr lens-view source) `(▹ ,x))) ,ds ...)
     (lens-transform/list source
                          c [(▹ ,x) ↦ ,x]
                          b [,x ↦ (▹ ,x)])]
    [`(,(and a (app (curryr lens-view source) `(▹ ,x))) ,cs ... ,d)
     (lens-transform/list source
                          a [(▹ ,x) ↦ ,x]
                          d [,x ↦ (▹ ,x)])]
    [_ source]))


(define (▹-cycle-▹▹ source)
  (match ((?->lenses [`(▹ ,a) ≡]) source)
    ['() ([(s▹ ,buf ,sel) ⋱↦ (s▹ ,buf ,(▹-first-▹▹-in sel))] source)]
    [_ (▹-next-▹▹ source)]))


#; (define-namespace-anchor an)
#; (define ns (namespace-anchor->namespace an))
#; (define (eval-match-λ pat-tem)
     (match-let ([`(,pat ,tem) pat-tem])
       (eval `(match-lambda [,pat ,tem] [x x]) ns)))
#; (define (eval-match-? pat)
     (eval `(match-lambda [(and x ,pat) x] [_ #f]) ns))

(define (buf->pat+tem buf)
  `[(and x (? symbol? (app symbol->string (regexp (regexp ,(string-append "^" buf ".*"))))))
    `(▹▹ ,x)])


(define ((search-map-rec fn) source) 
  (match (fn source)
    [`(▹▹ ,x) `(▹▹ ,x)]
    [(? list? ls) (map (curry search-map-rec fn) ls)]
    [(? atom? a) a]))


; single largest source of trivial bugs for me this project: copying a recursive function without changing the name of the rec call


(define ▹▹tag-hit (compose eval-match-λ buf->pat+tem))

(define (▹▹tag-hits str) (search-map-rec (▹▹tag-hit str)))


(define (remove-last-char-str str)
  (let ([length (sub1 (string-length str))])
    (if (> 0 length) "" (substring str 0 length))))


(define ((append-char-to-str key-code) str)
  (string-append str (string key-code)))


(define (append-char-to key-code)
  (compose string->symbol
           (append-char-to-str key-code)
           symbol->string))


(define remove-last-char
  (compose string->symbol
           remove-last-char-str
           symbol->string))


(define (remove-last-char-splice s)
  (let ([new (remove-last-char-str (symbol->string s))])
    (if #t #;(non-empty-string? new) `(,(string->symbol new)) `())))


(define/match (project-symbol fruct)
  [(`(,x ,xs ...)) (map project-symbol xs)]
  [((hash-table ('symbol s))) s])


(define empty-symbol (string->symbol ""))

(define empty-symbol? (curry equal? empty-symbol))


; helpers - autocomplete

(define auto-forms '((if (c▹▹ true) expr expr)
                     (begin expr)
                     (define name expr)
                     (cond [(c▹▹ expr) expr])
                     (define (name name) expr)
                     (let ([name expr]) expr)))


#; (define (replace-with-first-autocomplete-match source)
     ([(c▹ ,(and pat (app autocomplete-matches matches)) ,sel)
       ⋱↦ (c▹ ,(if (empty? matches)
                   pat
                   `(c▹▹ ,(first matches))) ,sel)] source))


(define (replace-with-first-autocomplete-match source)
  ([(c▹ ,(and pat (app autocomplete-matches matches)) ,sel)
    ⋱↦ (c▹ ,(if (empty? matches)
                pat
                (first matches)) ,sel)] source))


(define (autocomplete-matches pat)
  (filter-map (eval-match-? (map-rec redotdotdot (\\ (make-matcher pat)))) auto-forms))


(define/match (make-matcher source)
  [(`(c▹▹ ,(? empty-symbol?))) (// (gensym))]
  [(`(c▹▹ ,(? symbol? s))) (// (partial-symbol-match s))]
  [((? (disjoin symbol? number?) s)) s]
  [(`(,xs ...)) `(,@(map make-matcher xs) (ooo ,(// (gensym))))])


#; (define autocomplete-matches
     (compose (curryr filter-map auto-forms)
              eval-match-?
              (curry map-rec redotdotdot)
              \\
              make-matcher))


(define (partial-symbol-match s)
  `(? symbol? (app symbol->string (regexp (string-append "^" ,(symbol->string s) ".*")))))


; helpers - pattern painting
((contains- ['⋈ ≡]) '⋈)
((contains- ['⋈ ≡]) '(⋈ a b))
((contains- ['⋈ ≡]) '(a b ⋈))
((contains- ['⋈ ≡]) '((⋈ a) b))
((contains- ['⋈ ≡]) '(a (⋈ b)))

; todo : make sure you can't select within the command you're currently writing
(define (simple-paint source)
  (match ((?->lenses [(or `(⋈ ,_ ,_) `(▹ ,_)) ≡]) source)
    [`(,(and a (app (curryr lens-view source) `(▹ ,(or (not '⋈ `(⋈  ,_ ,_) (? (contains- ['⋈ ≡]))) (? atom?))))) ; atom is hack
       ,(and bs (app (curryr lens-view source) `(⋈ ,_ ,_))) ...)
     (let ([new-source (lens-transform a source [(▹ ,c) ↦ (▹ (⋈ 0 ,c))])])
       (if (empty? bs) new-source (lens-transform (apply lens-join/list bs) new-source (curry map [(⋈ ,m ,x) ↦ (⋈ ,(add1 m) ,x)]))))]
    [`(,(app (curryr lens-view source) `(⋈ ,_ ,as)) ...
       ,(app (curryr lens-view source) `(⋈ ,n ,b))
       ,(and c (app (curryr lens-view source) `(▹ ,_)))
       ,(and ds (app (curryr lens-view source) `(⋈ ,_ ,_))) ...)
     (let ([new-source (lens-transform c source [(▹ ,c) ↦ (▹ (⋈ ,(add1 n) ,c))])])
       (if (empty? ds) new-source (lens-transform (apply lens-join/list ds) new-source (curry map [(⋈ ,m ,x) ↦ (⋈ ,(add1 m) ,x)]))))]
    [_ source]))


; bug with simple-paint:
; turn into test case
#; '(((▹ ⋈) 0 define)
     (fn a)
     a
     (define (g q r) (let ((a 5) (b 6)) (if apple banana orange))))
#; '(((▹ (⋈ 0 ⋈)) 0 define)
     (fn a)
     a
     (define (g q r) (let ((a 5) (b 6)) (if apple banana orange))))

; most local solution: make simple-paint identity in case of (▹ ⋈)
; current general idea: prohibit selection of (some?) affordances
; property of affordances: selectability
; option: if not selectable: when selected, select first child or next sibling
; option: selection modes. usual mode doesn't have some affos as selectable
; subselectability: ability to select affordance icon, subparts

; idea: independently make file manager based on interface concept
; basically can create/delete/navigate/search folders/rkt-files
; maybe lang lines and modules in files? require/provide hooks?

(define (named-paint-c▹▹ name)
  [(c▹▹ ,a) ⋱↦ (c▹▹ (⋈ ,name _))])


(define (eval-painted-buffer buf sel)
  (match buf
    [`(⋈ ,name ,_) (lookup-binding-value name sel)]
    [(? atom?) buf]
    [(? list?) (map (curryr eval-painted-buffer sel) buf)]))


(define (lookup-binding-value name sel)
  (match-let ([`(⋈ ,_ ,val) (lens-view (first ((?->lenses [`(⋈ ,(== name) ,_) ≡]) sel)) sel)])
    val))


(define (form-paint sel)
  (match sel
    [`(if ,a ,b ,c) `(if (⋈ 0 ,a) (⋈ 1 ,b) (⋈ 2 ,c))]
    [`(begin ,as ...) `(begin ,@(map (λ (n x) `(⋈ n ,x)) (range (length as)) as))]))


(define (toggle-paint sel)
  (match sel
    [`(,(not (== '⋈)) ,a ...) `(⋈ 0 ,sel)]
    [`(⋈ ,_ ,sel) (form-paint sel)]))


; main loop ---------------------------------------------

; todo:
; make command to re-root the tree on current selection, and to expand selection if root selected
; make quick !!! command to collapse a subtree (remember to remember state)


; macro attempt 1
#; (match key-code                      
     [#\return               (!do ([((▹ ,(? form-name? a)) ,x ...) ⋱↦ (c▹ (c▹▹ ,empty-symbol) (,a ,@x))]
                                   [(▹ ,a) ⋱↦ (c▹ (c▹▹ ,empty-symbol) ,a)])) 
                             (set! mode 'transform)]
     ['down                  (!do [(▹ (,a ,b ...)) ⋱↦ ((▹ ,a) ,@b)])])
#; (match key-code [key-pat (!do a-transformation) ...
                            (~optional (set! mode 'a-mode))] ...)
(require syntax/parse)
#; (define/syntax-parse (match-do! key-code [key-pat a-transformation (~optional (mode: a-mode))] ...)
     (match key-code [key-pat (!do a-transformation)
                              (~optional (set! mode 'a-mode))] ...))
#;(define-syntax (match-do! stx)
    (syntax-case stx (mode:)
      [ (_ key-code [key-pat a-transformation (mode: a-mode) ...] ...)
        #`(match key-code [key-pat (!do a-transformation)
                                   (set! mode a-mode) ...] ...)]))


; macro attempt 2
#; (main-loop event
              [amodal-key amodal-action]
              ...
              (a-mode
               [a-key an-action] ...)
              ...)
#; (define (char-input event)
     (let ([key-code (send event get-key-code)])
       (when (not (equal? 'release key-code))
         (match key-code
           [amodal-key amodeal-action]
           [_ (case mode
                [a-mode     (match key-code
                              [a-key     an-action])])])))) 




; potential format for main loop macro
#; (main-loop
    
    ; amodal functions
    ['f1 (!do (λ (_) backup-stage))] ; restores stage to initial state
    ['f2 (pretty-print (project-symbol stage-gui))] ; print s-expr representing stage
    ['f3 (pretty-print stage-gui)] ; print raw stage data

    (SELECT     
     ['home                  [,a ⋱↦ (▹ ,a)] [(▹ ,a) ⋱↦ ,a]]                         
     [#\return               ([((▹ ,(? form-name? a)) ,x ...) ⋱↦ (c▹ (c▹▹ ,empty-symbol) (,a ,@x))]
                              [(▹ ,a) ⋱↦ (c▹ (c▹▹ ,empty-symbol) ,a)]) 
                             (mode: TRANSFORM)]
                           
     ['right                 (▹-next-? atom?)]
     ['left                  (▹-prev-? atom?)]
     )
  
    (PROJECT))





(define (char-input event)
  (let ([key-code (send event get-key-code)])
    (when (not (equal? 'release key-code))
      (match key-code
        
        ['f1 (!do (λ (_) backup-stage))] ; restores stage to initial state
        ['f2 (pretty-print (project-symbol stage-gui))] ; print s-expr representing stage
        ['f3 (pretty-print stage-gui)] ; print raw stage data
        
        [_ (case mode
             
             ['select    (match key-code
                           
                           ['home                  (!do (compose [,a ⋱↦ (▹ ,a)] [(▹ ,a) ⋱↦ ,a]))]
                           
                           [#\return               (!do ([((▹ ,(? form-name? a)) ,x ...) ⋱↦ (c▹ (c▹▹ ,empty-symbol) (,a ,@x))]
                                                         [(▹ ,a) ⋱↦ (c▹ (c▹▹ ,empty-symbol) ,a)])) 
                                                   (set! mode 'transform)]
                           
                           ['right                 (!do (▹-next-? atom?))]
                           ['left                  (!do (▹-prev-? atom?))]
                           ['up                    (!do [(,a ... (▹ ,b ...) ,c ...) ⋱↦ (▹ (,@a ,@b ,@c))])]
                           ['down                  (!do [(▹ (,a ,b ...)) ⋱↦ ((▹ ,a) ,@b)])]
                           
                           [#\space                (!do ([(▹ ,(and a (? atom?))) ⋱↦ (▹ ,a)] ; why isn't this working
                                                         [(▹ ⋈) ⋱↦ (▹ ⋈)] ; redundant to below
                                                         [(▹ (⋈ ,a ,b)) ⋱↦ (▹ (⋈ ,a ,b))]
                                                         [(▹ ,(and a (? (contains- ['⋈ ≡])))) ⋱↦ (▹ ,a)]
                                                         [,x ⋱↦ ,(simple-paint x)]))]
                           
                           ['escape                (!do {(⋈ ,a ,b) ⋱↦ ,b})]
                           
                           [(reg "[A-Za-z_]")      (!do [(▹ ,a) ⋱↦ (s▹ ,(string key-code) ,((▹▹tag-hits (string key-code)) a))])
                                                   (set! mode 'search)])

                         #;(match-do! key-code
                                      ['down [(▹ (,a ,b ...)) ⋱↦ ((▹ ,a) ,@b)]]
                                      (mode: 'transform))]
             
             ['search    (match key-code
                           
                           [(or 'escape #\return)  (!do (compose [(s▹ ,buf ,sel) ⋱↦ (▹ ,sel)]
                                                                 [(▹▹ ,a) ⋱↦ ,a]))
                                                   (set! mode 'select)]
                           
                           ['right                 (!do ▹-cycle-▹▹)]
                           
                           [(or #\backspace) (!do [(s▹ ,buf ,sel) ⋱↦ ,(let ([bu (remove-last-char-str buf)])
                                                                        `(s▹ ,bu ,((▹▹tag-hits bu) sel)))])]
                           
                           [(reg "[A-Za-z0-9_]")   (!do [(s▹ ,buf ,sel) ⋱↦ ,(let ([new ((append-char-to-str key-code) buf)])
                                                                              `(s▹ ,new ,((▹▹tag-hits new) sel)))])])]
             
             
             ['transform (match key-code
                           
                           ['escape                (!do (compose [(c▹ ,buf ,sel) ⋱↦ (▹ ,sel)]
                                                                 [(⋈ ,num ,sel) ⋱↦ ,sel]
                                                                 #; [(,a ... ,(? empty-symbol?) ,b ...) ⋱↦ (,@a ,@b)]))
                                                   (set! mode 'select)]
                           
                           [#\return               (!do [(c▹ ,buf ,sel) ⋱↦ (▹ ,(([(c▹▹ ,x) ⋱↦ ,x]) (eval-painted-buffer buf sel)))])
                                                   (set! mode 'select)]
                           
                           [(or 'right #\space)    (!do ([(,as ...  (c▹▹ ,(? empty-symbol?))) ⋱↦ (,@as (c▹▹ ,empty-symbol))]
                                                         [(,as ...  (c▹▹ ,b)) ⋱↦ (,@as ,b  (c▹▹ ,empty-symbol))]
                                                         [(,(and as (not (== 'c▹))) ...  (c▹▹ ,b) ,c ,cs ...) ⋱↦ (,@as ,b  (c▹▹ ,c) ,@cs)]
                                                         [(c▹▹ ,(? empty-symbol?)) ⋱↦ (c▹▹ ,empty-symbol)]
                                                         [(c▹▹ ,a) ⋱↦ (,a  (c▹▹ ,empty-symbol))]))]
                           
                           ['down                  (!do ([(c▹▹ ,a) ⋱↦ ((c▹▹ ,a))]))]
                           
                           ['up                    (!do ([(,as ... (,bs ... (c▹▹ ,(? empty-symbol?)))) ⋱↦ (,@as (,@bs) (c▹▹ ,empty-symbol))]
                                                         [(,as ... (,bs ... (c▹▹ ,c))) ⋱↦ (,@as (,@bs ,c) (c▹▹ ,empty-symbol))]))]
                           
                           [(or 'left #\backspace) (!do ([((c▹▹ ,(? empty-symbol?)) ,as ...) ⋱↦ (c▹▹ ,empty-symbol)]
                                                         [(c▹▹ ,(? symbol? s)) ⋱↦  (c▹▹ ,(remove-last-char s))]
                                                         [(c▹▹ ,(? atom? s)) ⋱↦  (c▹▹ ,empty-symbol)]
                                                         [(c▹ (c▹▹ ,(? empty-symbol?)) ,xs ...) ⋱↦  (c▹ (c▹▹ ,empty-symbol) ,@xs)]
                                                         [(,xs ... ,(? atom? x) (c▹▹ ,(? empty-symbol?)) ,ys ...) ⋱↦  (,@xs (c▹▹ ,x) ,@ys)]
                                                         [(,xs ... (,as ...) (c▹▹ ,(? empty-symbol? s)) ,ys ...) ⋱↦  (,@xs (,@as (c▹▹ ,empty-symbol)) ,@ys)]))]
                           
                           [(reg "[0-9]")          (!do (named-paint-c▹▹ (string->number (string key-code))))]
                           ['control               (!do [(c▹ ,buf ,sel) ⋱↦ (c▹ ,buf ,(toggle-paint sel))])]
                           [#\tab                  (!do replace-with-first-autocomplete-match)]
                           [(reg "[A-Za-z_]")      (!do ([(c▹▹ ,(? symbol? s)) ⋱↦ (c▹▹ ,((append-char-to key-code) s))]))])]
             
             ['project   (match key-code)])]))))





; gui setup ---------------------------------------------

(define my-frame
  (new frame%
       [label "fructure"]
       [width 1300]
       [height 900]))

(define my-canvas
  (new editor-canvas%
       [parent my-frame]))


; testing ------------------------------------------------

; init stage and kit
(define stage
  #; '(if a b c)
  ((▹-first-?-in atom?) '(define (sub-sequences l)
                           (cond [(empty? l) (list (list))]
                                 [else (local [(define a-list (sub-sequences (rest l)))]
                                         (append a-list
                                                 (include-in-all (first l) a-list)))])))
  
  #; '((▹-first-?-in atom?) '(define (fn a) a (define (g q r) (let ([a 5] [b 6]) (if apple banana orange)))))
  #; '(▹ (define (fn a) a (define (g q r) (let ([a 5] [b 6]) (if 1 2 2)))))
  #; '(▹ (if a b c))
  #; '(define (fn a) a (define (g q r) (let ([a 5] [b 6]) (if 1 2 2))))
  #; '(define (fn a) a (define (g q r) 2))
  #; '(define (▹ (fn a)) 7))

(define backup-stage
  ((▹-first-?-in atom?) '(define (fn a) a (define (g q r) (let ([a 5] [b 6]) (if apple banana orange))))))

(define kit '(kit (env) (meta)))

; init gui refs
(define stage-gui '())
(define kit-gui '())

; init globals
(define mode 'select)

; init display
(send my-frame show #t)
(update-gui stage kit)






; tests -----------------------------------------------------

(module+ test (require rackunit)

  (check-equal? 0 0)

 
  
  #; (▹-next-▹▹ `(1 2 (8 9 (7 6 (▹▹ (▹ 3)) 5)) (▹▹ 4)))
  (check-equal? (▹-next-▹▹ `(1 2 (8 9 (7 6 (▹▹ (▹ 3)) 5)) (▹▹ 4)))
                '(1 2 (8 9 (7 6 (▹▹ 3) 5)) (▹▹ (▹ 4))))
  
  #; (▹-next-▹▹ (▹-next-▹▹ `(1 2 (8 9 (7 6 (▹▹ (▹ 3)) 5)) (▹▹ 4))))
  (check-equal? (▹-next-▹▹ (▹-next-▹▹ `(1 2 (8 9 (7 6 (▹▹ (▹ 3)) 5)) (▹▹ 4))))
                '(1 2 (8 9 (7 6 (▹▹ (▹ 3)) 5)) (▹▹ 4)))
  
  #; (▹-next-▹▹ (▹-next-▹▹ (▹-next-▹▹ `(1 2 (8 9 (7 6 (▹▹ (▹ 3)) 5)) (▹▹ 4)))))
  (check-equal? (▹-next-▹▹ (▹-next-▹▹ (▹-next-▹▹ `(1 2 (8 9 (7 6 (▹▹ (▹ 3)) 5)) (▹▹ 4)))))
                '(1 2 (8 9 (7 6 (▹▹ 3) 5)) (▹▹ (▹ 4))))

  #; (▹->lens `(1 2 (8 9 (7 6 (▹ 3) 5)) (▹ 4)))
  #; (lens-view (second (▹->lenses `(1 2 (8 9 (7 6 (▹ 3) 5)) (▹ 4)))) `(1 2 (8 9 (7 6 (▹ 3) 5)) (▹ 4)))

  #; ((?->lens [`(▹ ,a) ≡]) `(1 2 (8 9 (7 6 (▹ 3) 5)) (▹ 4)))
  #; (lens-view (second ((?->lenses [`(▹ ,a) ≡]) `(1 2 (8 9 (7 6 (▹ 3) 5)) (▹ 4)))) `(1 2 (8 9 (7 6 (▹ 3) 5)) (▹ 4)))

  #; (lens-view (second (▹▹->lenses `(1 2 (8 9 (7 6 (▹▹ 3) 5)) (▹▹ 4)))) `(1 2 (8 9 (7 6 (▹▹ 3) 5)) (▹▹ 4)))
  #; (lens-view (second (▹▹->lenses '((▹▹ (▹ define)) a ((▹▹ defne))))) '((▹▹ (▹ define)) a ((▹▹ defne))))
  #; (▹-next-▹▹ '((▹▹ (▹ define)) (fn a) a ((▹▹ define) (g q r) (let ([a 5] [b 6]) (if 1 2 2)))))

  #; ((eval-match-λ '`(,a ,b) 'a) '(1 5))
  #; (buf->pat+tem "def")

  #; (search-map-rec (eval-match-λ (buf->pat+tem "a")) '(a b a))
  #; (match "define"
       [(regexp (regexp "def.")) 777])
  #; (match (hash 'symbol 'a)
       [(app get-symbol-as-string (regexp (regexp (string-append "a" ".*")))) "blop"])
  #; ((curry map-rec (eval-match-λ (buf->pat "a") '111)) (hash 'symbol 'a))

  #; (buf->pat "def")
  #; ((eval-match-λ (buf->pat "def") 1) "deffine")
  #; ((eval-match-λ (buf->pat "a") '111) 'a)
  #; (get-symbol-as-string (sexp->fruct '(begin a b c)))


  
  #; ((make-gui (new fruct-ed%)) test-src )
  #; (source+grammar->form  '((selector let) (▹ ([f a][f a][k a][g a])) 4 4 4) '((if expr expr expr)
                                                                                 (begin expr ...)
                                                                                 (define (name name ...) expr ...)
                                                                                 (let ([name expr] ...) expr ...)))
  #; (pretty-print (sexp->fruct test-src))
  #; test-src
  #; (project-symbol (sexp->fruct test-src))
  #; (map-into-fruct (sexp->fruct test-src) [(hash-table ('self s)) s])
  #; (map-into test-src ['a 'b])


 
  #; (lookup-style-in '((background-color (color 247 0 114))
                        (text-color (parent text-color))
                        (border-style square-brackets)
                        (border-color (color 255 255 255)))
                      'border-style)

  #; ((fill-in-parent-refs
       '((background-color (color 247 0 18674))
         (text-color (color 999 999 999)) ))
      '((background-color (color 247 0 114))
        (text-color (parent text-color))
        (border-style square-brackets)
        (border-color (color 255 255 255))))




  #; (map-rec redotdotdot (make-matcher '((c▹▹ def))))
  #; (filter-map (eval-match-? (map-rec redotdotdot (\\ (make-matcher '((c▹▹ def)))))) forms)
  #; (map-rec redotdotdot (make-matcher '(define (f a (c▹▹ ||)))))
  #; (filter-map (eval-match-? (map-rec redotdotdot (\\ (make-matcher '(define (f a (c▹▹ ||))))))) '((define (f a b))))
  #; (map-rec redotdotdot (make-matcher '(let ((a (c▹▹ |2|))))))
  #; (filter-map (eval-match-? (map-rec redotdotdot (\\ (make-matcher '(let ((a (c▹▹ bag)))))))) '((let ((a bag))) (let ((a baggo)) 5) (let ((a baggo) 4)) (let ((a 3)))))

  ;we have:
  #; (c▹ ((c▹▹ def)) whatever)
  ; which means we're looking for stuff that looks like this matcher:
  #; (c▹ ((regexp "^def*") ,x ...) whatever)
  ; let's say this is the first result:
  #; (c▹ (define name expr) whatever)
  ; so we want this:
  #; (c▹ ((c▹▹ define) name expr) whatever)
  ; or maybe this:
  #; (c▹ (define (c▹▹ name) expr) whatever)

  ; so let's filter-map the matcher over a list of forms

  #; (c▹ (define (f a (c▹▹ ||))) whatever)
  #; (c▹ (define (f a ,sel ,y ...) ,z ...) whatever)

  #; (c▹ (let ((a (c▹▹ |2|)))) whatever)
  #; (c▹ (let ((a (regexp "^2*") ,x ...) ,y ...) ,z ...) whatever)

  ; we want to put the subselector back in afterwords, so let's keep track of it
  ; it can be replaced by either a pattern var (if subsel'd is empty symbol)
  ; or a regexp (if subsel'd is non-empty symbol)



  #; (lookup-binding-value 0 `(4 5 ( 3 (⋈ 0 9))))

  )