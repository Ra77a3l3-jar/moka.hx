(require "helix/components.scm")
(require "helix/configuration.scm")
(require "helix/misc.scm")
(require "helix/editor.scm")
(require "helix/static.scm")
(require "glyph/glyph.scm")

(provide moka-segment
         moka-section
         moka-configure!
         moka-enable!
         moka-disable!
         moka-refresh-git!)

(struct MokaSegment (content fg bg))
(struct MokaSection (align segments))

(define (moka-segment content #:fg [fg 'auto] #:bg [bg 'auto])
  (MokaSegment content fg bg))

(define (moka-section segments #:align [align 'left])
  (MokaSection align segments))

(define *moka-row-offset* 2)
(define *moka-transparent?* #t)
(define *moka-sections* '())
(define *moka-enabled?* #f)
(define *moka-hooks-registered?* #f)

;; render only reads these, never calls editor-focus directly (crashes helix)
(define *moka-mode* "NOR")
(define *moka-path* #f)
(define *moka-dirty?* #f)
(define *moka-lsp* "")
(define *moka-line* 0)
(define *moka-col* 0)

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

(define *moka-mode-insert* (string->editor-mode "insert"))
(define *moka-mode-select* (string->editor-mode "select"))

(define (moka-configure! #:row-offset [row-offset 2]
                          #:transparent? [transparent? #t]
                          #:sections [sections '()]
                          #:colors [colors *moka-default-colors*])
  (set! *moka-row-offset* row-offset)
  (set! *moka-transparent?* transparent?)
  (set! *moka-sections* sections)
  (set! *moka-colors* colors))

(define (moka-base-style)
  (if *moka-transparent?* (theme-scope-ref "ui.background") (theme-scope-ref "ui.statusline")))

;; mode/git-branch default to a colored pill, everything else stays plain
(define (moka-default-bg content)
  (cond
    [(equal? content 'mode) (hash-try-get *moka-colors* 'mode-fallback-bg)]
    [(equal? content 'git-branch) (hash-try-get *moka-colors* 'git-branch-bg)]
    [else #f]))

(define (moka-default-fg content)
  (cond
    [(equal? content 'mode) (hash-try-get *moka-colors* 'mode-fallback-fg)]
    [(equal? content 'git-branch) (hash-try-get *moka-colors* 'git-branch-fg)]
    [(equal? content 'lsp) (hash-try-get *moka-colors* 'lsp)]
    [(equal? content 'position) (hash-try-get *moka-colors* 'position)]
    [else #f]))

(define (moka-resolve value default)
  (if (equal? value 'auto) default value))

(define (moka-segment-bg segment)
  (moka-resolve (MokaSegment-bg segment) (moka-default-bg (MokaSegment-content segment))))

(define (moka-segment-fallback-fg segment)
  (moka-resolve (MokaSegment-fg segment) (moka-default-fg (MokaSegment-content segment))))

;; no subprocess, safe on every keystroke
(define (moka-refresh-fast!)
  (define doc-id (editor->doc-id (editor-focus)))
  (set! *moka-mode*
        (cond
          [(equal? (editor-mode) *moka-mode-insert*) "INS"]
          [(equal? (editor-mode) *moka-mode-select*) "SEL"]
          [else "NOR"]))
  (set! *moka-path* (editor-document->path doc-id))
  (set! *moka-dirty?* (editor-document-dirty? doc-id))
  (set! *moka-lsp*
        (let ([clients (get-active-lsp-clients)])
          (if (null? clients) "" (string-join (map lsp-client-name clients) ", "))))
  (set! *moka-line* (get-current-line-number))
  (set! *moka-col* (get-current-column-number)))

(define (moka-git-repo? dir)
  (define proc
    (~> (command "git" (list "-C" dir "rev-parse" "--is-inside-work-tree"))
        with-stdout-piped
        with-stderr-piped
        spawn-process))
  (and (Ok? proc) (equal? (trim (read-port-to-string (child-stdout (Ok->value proc)))) "true")))

(define (moka-read-branch dir)
  (define proc
    (~> (command "git" (list "-C" dir "rev-parse" "--abbrev-ref" "HEAD"))
        with-stdout-piped
        with-stderr-piped
        spawn-process))
  (if (Ok? proc) (trim (read-port-to-string (child-stdout (Ok->value proc)))) ""))

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
  (define proc
    (~> (command "git" (list "-C" root "status" "--porcelain"))
        with-stdout-piped
        with-stderr-piped
        spawn-process))
  (if (Ok? proc)
      (let* ([output (read-port-to-string (child-stdout (Ok->value proc)))]
             [lines (filter (lambda (l) (> (string-length l) 0)) (split-many output "\n"))])
        (moka-parse-status-lines lines))
      (hash)))

;; shells out to git, so only on save/open/focus, not every keystroke
(define (moka-refresh-git!)
  (define root (helix-find-workspace))
  (if (moka-git-repo? root)
      (begin
        (set! *moka-git-branch* (moka-read-branch root))
        (set! *moka-git-status-map* (moka-scan-git-status root)))
      (begin
        (set! *moka-git-branch* "")
        (set! *moka-git-status-map* (hash)))))

(define (moka-relpath path)
  (define prefix (string-append (helix-find-workspace) (path-separator)))
  (if (and (>= (string-length path) (string-length prefix))
           (equal? (substring path 0 (string-length prefix)) prefix))
      (substring path (string-length prefix) (string-length path))
      path))

(define (moka-current-git-status)
  (if *moka-path* (hash-try-get *moka-git-status-map* (moka-relpath *moka-path*)) #f))

(define (moka-mode-content) *moka-mode*)

;; each content from glyph uses their original colors
(define (moka-file-content)
  (if (not *moka-path*)
      ""
      (let* ([name (file-name *moka-path*)]
             [status (moka-current-git-status)]
             [base (list (cons (glyph-icon name) (glyph-color name)) (cons " " #f))]
             [with-status
              (if status
                  (append base (list (cons (glyph-git-icon status) (glyph-git-color status)) (cons " " #f)))
                  base)]
             [with-name (append with-status (list (cons name #f)))])
        (if *moka-dirty?*
            (append with-name (list (cons " " #f) (cons "*" (hash-try-get *moka-colors* 'dirty))))
            with-name))))

(define (moka-git-branch-content) *moka-git-branch*)

(define (moka-lsp-content) *moka-lsp*)

(define (moka-position-content)
  (string-append (number->string (+ 1 *moka-line*)) ":" (number->string (+ 1 *moka-col*))))

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

;; fragments without their own inherent color fall back to the segment's #:fg
(define (moka-segment-runs segment)
  (define fallback-fg (moka-segment-fallback-fg segment))
  (map (lambda (frag) (cons (car frag) (or (cdr frag) fallback-fg))) (moka-content-fragments segment)))

(define (moka-segment-text segment)
  (string-join (map car (moka-segment-runs segment)) ""))

(define (moka-segment-width segment)
  (string-length (moka-segment-text segment)))

(define (moka-sections-for align)
  (filter (lambda (sec) (equal? (MokaSection-align sec) align)) *moka-sections*))

(define (moka-section-segments-nonempty section)
  (filter (lambda (seg) (> (moka-segment-width seg) 0)) (MokaSection-segments section)))

(define (moka-section-width section)
  (define segs (moka-section-segments-nonempty section))
  (if (null? segs) 0 (+ (apply + (map moka-segment-width segs)) (* 2 (- (length segs) 1)))))

(define (moka-sections-nonempty align)
  (filter (lambda (sec) (> (moka-section-width sec) 0)) (moka-sections-for align)))

(define (moka-align-width align)
  (define secs (moka-sections-nonempty align))
  (if (null? secs) 0 (+ (apply + (map moka-section-width secs)) (* 2 (- (length secs) 1)))))

;; bg is shared across the whole segment (the "pill"), fg is per-fragment
(define (moka-draw-segment! frame x y segment base-style)
  (define bg (moka-segment-bg segment))
  (define bg-style (if bg (style-bg base-style (glyph-hex->color bg)) base-style))
  (let loop ([runs (moka-segment-runs segment)] [cx x])
    (if (null? runs)
        cx
        (let* ([run (car runs)]
               [text (car run)]
               [fg (cdr run)]
               [run-style (if fg (style-fg bg-style (glyph-hex->color fg)) bg-style)])
          (frame-set-string! frame cx y text run-style)
          (loop (cdr runs) (+ cx (string-length text)))))))

(define (moka-draw-section! frame x y section base-style)
  (let loop ([segs (moka-section-segments-nonempty section)] [cx x])
    (if (null? segs)
        cx
        (let ([next-cx (moka-draw-segment! frame cx y (car segs) base-style)])
          (if (null? (cdr segs)) next-cx (loop (cdr segs) (+ next-cx 2)))))))

(define (moka-draw-align! frame x y align base-style)
  (let loop ([secs (moka-sections-nonempty align)] [cx x])
    (if (null? secs)
        cx
        (let ([next-cx (moka-draw-section! frame cx y (car secs) base-style)])
          (if (null? (cdr secs)) next-cx (loop (cdr secs) (+ next-cx 2)))))))

(define (moka-render-bar state rect frame)
  (define width (area-width rect))
  (define height (area-height rect))
  (define y (- height *moka-row-offset*))
  (define base-style (moka-base-style))
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
    (register-hook 'post-command (lambda (name) (moka-refresh-fast!)))
    (register-hook 'post-insert-char (lambda (ch) (moka-refresh-fast!)))
    (register-hook 'on-mode-switch (lambda (ev) (moka-refresh-fast!)))
    (register-hook 'selection-did-change (lambda (view-id) (moka-refresh-fast!)))
    (register-hook 'document-opened
                    (lambda (doc-id)
                      (moka-refresh-fast!)
                      (moka-refresh-git!)))
    (register-hook 'document-saved
                    (lambda (doc-id)
                      (moka-refresh-fast!)
                      (moka-refresh-git!)))
    (register-hook 'terminal-focus-gained
                    (lambda ()
                      (moka-refresh-fast!)
                      (moka-refresh-git!)))
    (set! *moka-hooks-registered?* #t)))

(define (moka-enable!)
  (unless *moka-enabled?*
    (moka-blank-native-statusline!)
    (moka-register-hooks!)
    ;; tree isn't ready yet while init.scm is still loading
    (enqueue-thread-local-callback-with-delay
     50
     (lambda ()
       (moka-refresh-fast!)
       (moka-refresh-git!)))
    (push-component!
     (new-component! "moka" #f moka-render-bar (hash "cursor" moka-cursor-handler)))
    (set! *moka-enabled?* #t)))

(define (moka-disable!)
  (when *moka-enabled?*
    (pop-last-component-by-name! "moka")
    (moka-restore-native-statusline!)
    (set! *moka-enabled?* #f)))
