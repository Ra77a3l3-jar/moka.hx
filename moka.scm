(require "helix/components.scm")
(require "helix/configuration.scm")
(require "helix/misc.scm")
(require "helix/editor.scm")
(require "helix/static.scm")
(require "helix/commands.scm")
(require "glyph/glyph.scm")

(provide moka-segment
         moka-section
         moka-configure!
         moka-enable!
         moka-disable!
         moka-refresh-git!
         moka-buffer-style
         moka-bufferline-configure!
         moka-bufferline-enable!
         moka-bufferline-disable!
         moka-reserved-top
         moka-reserved-bottom)

(struct MokaSegment (content fg bg bubble? gap))
(struct MokaSection (align segments gap))

(define (moka-segment content #:fg [fg 'auto] #:bg [bg 'auto] #:bubble? [bubble? 'auto] #:gap [gap 2])
  (MokaSegment content fg bg bubble? gap))

(define (moka-section segments #:align [align 'left] #:gap [gap 2])
  (MokaSection align segments gap))

(define *moka-row-offset* 2)
(define *moka-transparent?* #t)
(define *moka-enabled?* #f)
(define *moka-hooks-registered?* #f)

(define *moka-git-branch* "")
(define *moka-git-status-map* (hash))

(define *moka-default-colors*
  (hash 'mode-fallback-bg "#585b70"
        'mode-fallback-fg "#1e1e2e"
        'git-branch-bg "#a6e3a1"
        'git-branch-fg "#1e1e2e"
        'lsp "#89b4fa"
        'position "#cba6f7"
        'dirty "#f9e2af"))

(define *moka-colors* *moka-default-colors*)

(define *moka-pill-left* "")
(define *moka-pill-right* "")
(define *moka-angle-left* "")
(define *moka-angle-right* "")

(define *moka-mode-insert* (string->editor-mode "insert"))
(define *moka-mode-select* (string->editor-mode "select"))

(define *moka-mode-labels* (hash 'normal "NOR" 'insert "INS" 'select "SEL"))

(define (moka-mode-label)
  (cond
    [(equal? (editor-mode) *moka-mode-insert*) (hash-try-get *moka-mode-labels* 'insert)]
    [(equal? (editor-mode) *moka-mode-select*) (hash-try-get *moka-mode-labels* 'select)]
    [else (hash-try-get *moka-mode-labels* 'normal)]))

(define (moka-mode-scope)
  (cond
    [(equal? (editor-mode) *moka-mode-insert*) "ui.statusline.insert"]
    [(equal? (editor-mode) *moka-mode-select*) "ui.statusline.select"]
    [else "ui.statusline.normal"]))

(define *moka-default-sections*
  (list (moka-section (list (moka-segment 'mode) (moka-segment 'file)) #:align 'left)
        (moka-section (list (moka-segment 'lsp) (moka-segment 'git-branch) (moka-segment 'position))
                       #:align 'right)))

(define *moka-sections* *moka-default-sections*)

(define (moka-configure! #:row-offset [row-offset 2]
                          #:transparent? [transparent? #t]
                          #:sections [sections *moka-default-sections*]
                          #:colors [colors *moka-default-colors*]
                          #:mode-normal [mode-normal "NOR"]
                          #:mode-insert [mode-insert "INS"]
                          #:mode-select [mode-select "SEL"])
  (set! *moka-row-offset* row-offset)
  (set! *moka-transparent?* transparent?)
  (set! *moka-sections* sections)
  (set! *moka-colors* colors)
  (set! *moka-mode-labels* (hash 'normal mode-normal 'insert mode-insert 'select mode-select)))

(define (moka-base-style)
  (if *moka-transparent?* (theme-scope-ref "ui.background") (theme-scope-ref "ui.statusline")))

;; 'mode prefers theme colors over the hash
(define (moka-default-bg content)
  (cond
    [(equal? content 'mode)
     (or (style->bg (theme-scope-ref (moka-mode-scope))) (hash-try-get *moka-colors* 'mode-fallback-bg))]
    [(equal? content 'git-branch) (hash-try-get *moka-colors* 'git-branch-bg)]
    [else #f]))

(define (moka-default-fg content)
  (cond
    [(equal? content 'mode)
     (or (style->fg (theme-scope-ref (moka-mode-scope))) (hash-try-get *moka-colors* 'mode-fallback-fg))]
    [(equal? content 'git-branch) (hash-try-get *moka-colors* 'git-branch-fg)]
    [(equal? content 'lsp) (hash-try-get *moka-colors* 'lsp)]
    [(equal? content 'position) (hash-try-get *moka-colors* 'position)]
    [else #f]))

(define (moka-resolve value default-thunk)
  (if (equal? value 'auto) (default-thunk) value))

;; hex string or already-built Color?
(define (moka-to-color value)
  (if (string? value) (glyph-hex->color value) value))

(define (moka-caps-for bg bubble?)
  (cond
    [(not bg) #f]
    [(equal? bubble? #t) (cons *moka-pill-left* *moka-pill-right*)]
    [(equal? bubble? 'angled) (cons *moka-angle-left* *moka-angle-right*)]
    [else #f]))

(define (moka-runs-for fragments bg fallback-fg)
  (define fg (or fallback-fg (and bg "#1e1e2e")))
  (if bg
      (map (lambda (frag) (cons (car frag) fg)) fragments)
      (map (lambda (frag) (cons (car frag) (or (cdr frag) fg))) fragments)))

(define (moka-fragments-text fragments)
  (string-join (map car fragments) ""))

(define (moka-pad-fragments fragments bg)
  (if bg (append (list (cons " " #f)) fragments (list (cons " " #f))) fragments))

(define (moka-styled-width fragments bg bubble?)
  (+ (string-length (moka-fragments-text (moka-pad-fragments fragments bg)))
     (if (moka-caps-for bg bubble?) 2 0)))

(define (moka-draw-styled! frame x y fragments bg bubble? fallback-fg base-style)
  (define bg-style (if bg (style-bg base-style (moka-to-color bg)) base-style))
  (define caps (moka-caps-for bg bubble?))
  (define cap-style (if bg (style-fg base-style (moka-to-color bg)) base-style))
  (define start-x
    (if caps
        (begin
          (frame-set-string! frame x y (car caps) cap-style)
          (+ x 1))
        x))
  (define end-x
    (let loop ([runs (moka-runs-for (moka-pad-fragments fragments bg) bg fallback-fg)] [cx start-x])
      (if (null? runs)
          cx
          (let* ([run (car runs)]
                 [text (car run)]
                 [fg (cdr run)]
                 [run-style (if fg (style-fg bg-style (moka-to-color fg)) bg-style)])
            (frame-set-string! frame cx y text run-style)
            (loop (cdr runs) (+ cx (string-length text)))))))
  (if caps
      (begin
        (frame-set-string! frame end-x y (cdr caps) cap-style)
        (+ end-x 1))
      end-x))

(define (moka-segment-bg segment)
  (moka-resolve (MokaSegment-bg segment) (lambda () (moka-default-bg (MokaSegment-content segment)))))

(define (moka-segment-fallback-fg segment)
  (moka-resolve (MokaSegment-fg segment) (lambda () (moka-default-fg (MokaSegment-content segment)))))

;; mode/git-branch default to round pills
(define (moka-default-bubble? content)
  (cond
    [(equal? content 'mode) #t]
    [(equal? content 'git-branch) #t]
    [else #f]))

(define (moka-segment-bubble? segment)
  (moka-resolve (MokaSegment-bubble? segment) (lambda () (moka-default-bubble? (MokaSegment-content segment)))))

;; read live, no caching
(define (moka-current-path)
  (with-handler (lambda (_) #f) (cx->current-file)))

(define (moka-current-dirty?)
  (with-handler (lambda (_) #f) (editor-document-dirty? (editor->doc-id (editor-focus)))))

(define (moka-current-lsp-names)
  (with-handler (lambda (_) '()) (map lsp-client-name (get-active-lsp-clients))))

(define (moka-git-repo? dir)
  (with-handler
    (lambda (_) #f)
    (define proc
      (~> (command "git" (list "-C" dir "rev-parse" "--is-inside-work-tree"))
          with-stdout-piped
          with-stderr-piped
          spawn-process))
    (and (Ok? proc) (equal? (trim (read-port-to-string (child-stdout (Ok->value proc)))) "true"))))

(define (moka-read-branch dir)
  (with-handler
    (lambda (_) "")
    (define proc
      (~> (command "git" (list "-C" dir "rev-parse" "--abbrev-ref" "HEAD"))
          with-stdout-piped
          with-stderr-piped
          spawn-process))
    (if (Ok? proc) (trim (read-port-to-string (child-stdout (Ok->value proc)))) "")))

(define (moka-git-status-symbol code)
  (define x (string-ref code 0))
  (define y (string-ref code 1))
  (cond
    [(and (char=? x #\?) (char=? y #\?)) 'untracked]
    [(or (char=? x #\A) (char=? y #\A)) 'added]
    [(or (char=? x #\D) (char=? y #\D)) 'deleted]
    [(or (char=? x #\R) (char=? y #\R)) 'renamed]
    [(or (char=? x #\M) (char=? y #\M)) 'modified]
    [else #f]))

(define (moka-status-path rest)
  (define parts (split-many rest " -> "))
  (trim-end-matches (if (> (length parts) 1) (list-ref parts (- (length parts) 1)) rest)
                     (path-separator)))

(define (moka-parse-status-lines lines)
  (let loop ([ls lines] [statuses (hash)])
    (if (null? ls)
        statuses
        (let ([line (car ls)])
          (if (< (string-length line) 3)
              (loop (cdr ls) statuses)
              (let* ([code (substring line 0 2)]
                     [path (moka-status-path (trim (substring line 3 (string-length line))))]
                     [sym (moka-git-status-symbol code)])
                (loop (cdr ls) (if sym (hash-insert statuses path sym) statuses))))))))

(define (moka-scan-git-status root)
  (with-handler
    (lambda (_) (hash))
    (define proc
      (~> (command "git" (list "-C" root "status" "--porcelain"))
          with-stdout-piped
          with-stderr-piped
          spawn-process))
    (if (Ok? proc)
        (let* ([output (read-port-to-string (child-stdout (Ok->value proc)))]
               [lines (filter (lambda (l) (> (string-length l) 0)) (split-many output "\n"))])
          (moka-parse-status-lines lines))
        (hash))))

;; shells out to git, so only on save/open/focus, not every keystroke
(define (moka-refresh-git!)
  (define root (with-handler (lambda (_) #f) (helix-find-workspace)))
  (if (and root (moka-git-repo? root))
      (begin
        (set! *moka-git-branch* (moka-read-branch root))
        (set! *moka-git-status-map* (moka-scan-git-status root)))
      (begin
        (set! *moka-git-branch* "")
        (set! *moka-git-status-map* (hash))))
  (redraw))

(define (moka-relpath path)
  (define prefix (string-append (helix-find-workspace) (path-separator)))
  (if (and (>= (string-length path) (string-length prefix))
           (equal? (substring path 0 (string-length prefix)) prefix))
      (substring path (string-length prefix) (string-length path))
      path))

(define (moka-current-git-status path)
  (and path (hash-try-get *moka-git-status-map* (moka-relpath path))))

(define (moka-mode-content) (moka-mode-label))

;; icon/status/name keep their own color
(define (moka-file-content)
  (define path (moka-current-path))
  (if (not path)
      ""
      (let* ([name (file-name path)]
             [status (moka-current-git-status path)]
             [base (list (cons (glyph-icon name) (glyph-color name)) (cons " " #f))]
             [with-status
              (if status
                  (append base (list (cons (glyph-git-icon status) (glyph-git-color status)) (cons " " #f)))
                  base)]
             [with-name (append with-status (list (cons name #f)))])
        (if (moka-current-dirty?)
            (append with-name (list (cons " " #f) (cons "*" (hash-try-get *moka-colors* 'dirty))))
            with-name))))

(define (moka-git-branch-content) *moka-git-branch*)

(define (moka-lsp-content) (string-join (moka-current-lsp-names) ", "))

(define (moka-position-content)
  (string-append (number->string (+ 1 (get-current-line-number)))
                  ":"
                  (number->string (+ 1 (get-current-column-number)))))

(define (moka-spacer-content) " ")
(define (moka-separator-content) "|")

(define *moka-content-registry*
  (hash 'mode moka-mode-content
        'file moka-file-content
        'git-branch moka-git-branch-content
        'lsp moka-lsp-content
        'position moka-position-content
        'spacer moka-spacer-content
        'separator moka-separator-content))

(define (moka-content-fragments segment)
  (define content (MokaSegment-content segment))
  (define raw
    (cond
      [(symbol? content)
       (define handler (hash-try-get *moka-content-registry* content))
       (if handler (handler) "")]
      [(procedure? content) (content)]
      [else ""]))
  (if (string? raw) (list (cons raw #f)) raw))

(define (moka-segment-text segment)
  (moka-fragments-text (moka-content-fragments segment)))

(define (moka-segment-width segment)
  (moka-styled-width (moka-content-fragments segment) (moka-segment-bg segment) (moka-segment-bubble? segment)))

(define (moka-sections-for align)
  (filter (lambda (sec) (equal? (MokaSection-align sec) align)) *moka-sections*))

;; caps alone don't count as content, drop segments with no actual text
(define (moka-section-segments-nonempty section)
  (filter (lambda (seg) (not (equal? (moka-segment-text seg) ""))) (MokaSection-segments section)))

;; adds gap-of after every item except last section
(define (moka-sum-with-gaps items width-of gap-of)
  (if (null? items)
      0
      (let loop ([xs items] [total 0])
        (if (null? (cdr xs))
            (+ total (width-of (car xs)))
            (loop (cdr xs) (+ total (width-of (car xs)) (gap-of (car xs))))))))

(define (moka-section-width section)
  (moka-sum-with-gaps (moka-section-segments-nonempty section) moka-segment-width MokaSegment-gap))

(define (moka-sections-nonempty align)
  (filter (lambda (sec) (> (moka-section-width sec) 0)) (moka-sections-for align)))

(define (moka-align-width align)
  (moka-sum-with-gaps (moka-sections-nonempty align) moka-section-width MokaSection-gap))

(define (moka-draw-segment! frame x y segment base-style)
  (moka-draw-styled! frame
                      x
                      y
                      (moka-content-fragments segment)
                      (moka-segment-bg segment)
                      (moka-segment-bubble? segment)
                      (moka-segment-fallback-fg segment)
                      base-style))

(define (moka-draw-section! frame x y section base-style)
  (let loop ([segs (moka-section-segments-nonempty section)] [cx x])
    (if (null? segs)
        cx
        (let* ([seg (car segs)]
               [next-cx (moka-draw-segment! frame cx y seg base-style)])
          (if (null? (cdr segs)) next-cx (loop (cdr segs) (+ next-cx (MokaSegment-gap seg))))))))

(define (moka-draw-align! frame x y align base-style)
  (let loop ([secs (moka-sections-nonempty align)] [cx x])
    (if (null? secs)
        cx
        (let* ([sec (car secs)]
               [next-cx (moka-draw-section! frame cx y sec base-style)])
          (if (null? (cdr secs)) next-cx (loop (cdr secs) (+ next-cx (MokaSection-gap sec))))))))

(define (moka-render-bar state rect frame)
  (define width (area-width rect))
  (define height (area-height rect))
  ;; clamped so offset 0 can't land off-screen
  (define y (max 0 (min (- height 1) (- height *moka-row-offset*))))
  (define base-style (moka-base-style))
  ;; the blanked native statusline still paints its bg
  ;; remove the row when the statusline is displayed on another line
  (define native-y (- height 2))
  (when (and (>= native-y 0) (not (= y native-y)))
    (buffer/clear-with frame (area 0 native-y width 1) base-style))
  (buffer/clear-with frame (area 0 y width 1) base-style)
  (moka-draw-align! frame 0 y 'left base-style)
  (define center-width (moka-align-width 'center))
  (when (> center-width 0)
    (moka-draw-align! frame (quotient (- width center-width) 2) y 'center base-style))
  (define right-width (moka-align-width 'right))
  (when (> right-width 0)
    (moka-draw-align! frame (- width right-width) y 'right base-style)))

(define (moka-cursor-handler state rect) #f)

(define (moka-blank-native-statusline!)
  (statusline #:left '() #:center '() #:right '()))

(define (moka-restore-native-statusline!)
  (statusline))

(define (moka-register-hooks!)
  (unless *moka-hooks-registered?*
    (register-hook 'document-saved (lambda (doc-id) (moka-refresh-git!)))
    (register-hook 'document-opened (lambda (doc-id) (moka-refresh-git!)))
    (register-hook 'terminal-focus-gained (lambda () (moka-refresh-git!)))
    (set! *moka-hooks-registered?* #t)))

(define (moka-enable!)
  (unless *moka-enabled?*
    (moka-blank-native-statusline!)
    (moka-register-hooks!)
    (moka-refresh-git!)
    (push-component!
     (new-component! "moka" #f moka-render-bar (hash "cursor" moka-cursor-handler)))
    (set! *moka-enabled?* #t)))

(define (moka-disable!)
  (when *moka-enabled?*
    (pop-last-component-by-name! "moka")
    (moka-restore-native-statusline!)
    (set! *moka-enabled?* #f)))

(struct MokaBufferStyle (fg bg bubble?))

(define (moka-buffer-style #:fg [fg 'auto] #:bg [bg 'auto] #:bubble? [bubble? 'auto])
  (MokaBufferStyle fg bg bubble?))

(define *moka-bufferline-enabled?* #f)
(define *moka-bufferline-hooks-registered?* #f)
(define *moka-bufferline-mode* 'multiple)
(define *moka-bufferline-row-offset* 0)
(define *moka-bufferline-gap* 1)
(define *moka-bufferline-show-icons?* #t)
(define *moka-bufferline-show-dirty?* #t)
(define *moka-bufferline-dirty-color* "#f9e2af")
(define *moka-bufferline-clickable?* #t)
(define *moka-bufferline-active-style* (moka-buffer-style #:bg "#89b4fa" #:fg "#1e1e2e" #:bubble? #t))
(define *moka-bufferline-inactive-style* (moka-buffer-style))

(define *moka-bufferline-tabs* '())

;; #:mode mirrors helix's own buferline settings never/always/multiple
(define (moka-bufferline-configure! #:row-offset [row-offset 0]
                                     #:mode [mode 'multiple]
                                     #:active [active (moka-buffer-style #:bg "#89b4fa"
                                                                          #:fg "#1e1e2e"
                                                                          #:bubble? #t)]
                                     #:inactive [inactive (moka-buffer-style)]
                                     #:gap [gap 1]
                                     #:icons? [icons? #t]
                                     #:dirty? [dirty? #t]
                                     #:dirty-color [dirty-color "#f9e2af"]
                                     #:clickable? [clickable? #t])
  (set! *moka-bufferline-row-offset* row-offset)
  (set! *moka-bufferline-mode* mode)
  (set! *moka-bufferline-active-style* active)
  (set! *moka-bufferline-inactive-style* inactive)
  (set! *moka-bufferline-gap* gap)
  (set! *moka-bufferline-show-icons?* icons?)
  (set! *moka-bufferline-show-dirty?* dirty?)
  (set! *moka-bufferline-dirty-color* dirty-color)
  (set! *moka-bufferline-clickable?* clickable?))

(define (moka-bufferline-style-for active?)
  (if active? *moka-bufferline-active-style* *moka-bufferline-inactive-style*))

(define (moka-bufferline-tab-bg style) (moka-resolve (MokaBufferStyle-bg style) (lambda () #f)))
(define (moka-bufferline-tab-fg style) (moka-resolve (MokaBufferStyle-fg style) (lambda () #f)))
(define (moka-bufferline-tab-bubble? style) (moka-resolve (MokaBufferStyle-bubble? style) (lambda () #f)))

(define (moka-bufferline-doc-fragments doc-id)
  (define path (with-handler (lambda (_) #f) (editor-document->path doc-id)))
  (define name (if path (file-name path) "[scratch]"))
  (define icon-frag
    (if (and *moka-bufferline-show-icons?* path)
        (list (cons (glyph-icon name) (glyph-color name)) (cons " " #f))
        '()))
  (define dirty? (and *moka-bufferline-show-dirty?* (with-handler (lambda (_) #f) (editor-document-dirty? doc-id))))
  (define dirty-frag (if dirty? (list (cons " " #f) (cons "*" *moka-bufferline-dirty-color*)) '()))
  (append icon-frag (list (cons name #f)) dirty-frag))

(define (moka-bufferline-docs)
  (with-handler (lambda (_) '()) (editor-all-documents)))

(define (moka-bufferline-focused-doc-id)
  (with-handler (lambda (_) #f) (editor->doc-id (editor-focus))))

(define (moka-bufferline-visible?)
  (cond
    [(equal? *moka-bufferline-mode* 'never) #f]
    [(equal? *moka-bufferline-mode* 'always) #t]
    [else (> (length (moka-bufferline-docs)) 1)]))

;; syncs the reserved top row from hooks
(define (moka-bufferline-sync-clip!)
  (set-editor-clip-top! (if (moka-bufferline-visible?) (+ *moka-bufferline-row-offset* 1) 0)))

;; draws nothing if bufferline set to hidden
(define (moka-render-bufferline state rect frame)
  (when (moka-bufferline-visible?)
    (define width (area-width rect))
    (define y *moka-bufferline-row-offset*)
    (define base-style (moka-base-style))
    (buffer/clear-with frame (area 0 y width 1) base-style)
    (define focused (moka-bufferline-focused-doc-id))
    (let loop ([docs (moka-bufferline-docs)] [cx 0] [tabs '()])
      (if (null? docs)
          (set! *moka-bufferline-tabs* (reverse tabs))
          (let* ([doc-id (car docs)]
                 [style (moka-bufferline-style-for (equal? doc-id focused))]
                 [fragments (moka-bufferline-doc-fragments doc-id)]
                 [start-x cx]
                 [end-x
                  (moka-draw-styled! frame
                                      cx
                                      y
                                      fragments
                                      (moka-bufferline-tab-bg style)
                                      (moka-bufferline-tab-bubble? style)
                                      (moka-bufferline-tab-fg style)
                                      base-style)])
            (loop (cdr docs) (+ end-x *moka-bufferline-gap*) (cons (list doc-id start-x end-x) tabs)))))))

(define (moka-bufferline-cursor-handler state rect) #f)

(define (moka-bufferline-tab-at col)
  (define hit (filter (lambda (tab) (and (>= col (cadr tab)) (< col (caddr tab)))) *moka-bufferline-tabs*))
  (if (null? hit) #f (car (car hit))))

(define (moka-bufferline-handle-event state event)
  (if (and *moka-bufferline-clickable?* (mouse-event? event) (equal? (event-mouse-kind event) 0)
           (equal? (event-mouse-row event) *moka-bufferline-row-offset*))
      (let ([doc-id (moka-bufferline-tab-at (event-mouse-col event))])
        (when doc-id
          (with-handler (lambda (_) #f) (editor-switch-action! doc-id Action/Replace)))
        event-result/consume)
      event-result/ignore))

(define (moka-bufferline-register-hooks!)
  (unless *moka-bufferline-hooks-registered?*
    (register-hook 'document-opened (lambda (doc-id) (moka-bufferline-sync-clip!)))
    (register-hook 'document-closed (lambda (closed-event) (moka-bufferline-sync-clip!)))
    (set! *moka-bufferline-hooks-registered?* #t)))

;; deactive helix default bufferline
(define (moka-bufferline-blank-native!)
  (with-handler (lambda (_) #f) (bufferline "never")))

(define (moka-bufferline-enable!)
  (unless *moka-bufferline-enabled?*
    (moka-bufferline-blank-native!)
    (moka-bufferline-register-hooks!)
    (moka-bufferline-sync-clip!)
    (push-component!
     (new-component! "moka-bufferline"
                      #f
                      moka-render-bufferline
                      (hash "cursor" moka-bufferline-cursor-handler
                            "handle_event" moka-bufferline-handle-event)))
    (set! *moka-bufferline-enabled?* #t)))

(define (moka-bufferline-disable!)
  (when *moka-bufferline-enabled?*
    (pop-last-component-by-name! "moka-bufferline")
    (set-editor-clip-top! 0)
    (set! *moka-bufferline-enabled?* #f)))

;;@doc
;; Number of rows the moka bufferline occupies at the top of the screen
(define (moka-reserved-top)
  (if (and *moka-bufferline-enabled?* (moka-bufferline-visible?))
      (+ *moka-bufferline-row-offset* 1)
      0))

;;@doc
;; Number of rows the moka statusline occupies at the bottom of the screen
(define (moka-reserved-bottom)
  (if *moka-enabled?* (max 1 *moka-row-offset*) 0))
