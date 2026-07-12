# Configuration

You build sections out of segments, hand them to `moka-configure!`, and call `moka-enable!`. That's it.

## Statusline

```scheme
(moka-configure!
 #:row-offset 2        ;; rows up from the bottom (bump it if the bar lands wrong)
 #:transparent? #t     ;; #t blends with the terminal bg, #f uses the theme's statusline fill
 #:mode-normal "NOR"   ;; rename the mode labels if you want
 #:mode-insert "INS"
 #:mode-select "SEL"
 #:sections (list ...) ;; the actual content, see below
 #:colors (hash ...))  ;; fallback colors, see below

(moka-enable!)
```

Everything is optional. `(moka-configure!)` alone gives you the default bar. Calling it again while the bar is running updates it live. `(moka-disable!)` puts Helix's statusline back.

### Sections

```scheme
(moka-section (list segment ...) #:align 'left #:gap 2)
```

`#:align` is `'left`, `'center`, or `'right`. `#:gap` is the spacing to the next section on the same side. Want two groups on the left? Just make two `'left` sections, they draw in order.

### Segments

```scheme
(moka-segment 'mode #:fg "#rrggbb" #:bg "#rrggbb" #:bubble? #t #:gap 2)
```

`#:fg` is the text color, `#:bg` is the fill (`#f` means none). `#:bubble?` picks the shape when there's a fill: `#t` round pill, `'angled` sharp powerline caps, `#f` flat block. `#:gap` is the spaces before the next segment (`0` means touching).

Heads up: `'mode` and `'git-branch` come with a background by default. If you want them as plain text, pass `#:bg #f` along with your `#:fg`.

### Built-in segments

| Name | Shows |
|---|---|
| `'mode` | `NOR` / `INS` / `SEL`, colored from the theme |
| `'file` | file icon + git status + name + `*` if unsaved |
| `'git-branch` | current branch (hidden outside a repo) |
| `'lsp` | attached LSP client name(s) (hidden if none) |
| `'position` | `line:column` |
| `'spacer` / `'separator` | a blank space / a `\|` |


### Custom segments

Instead of a built-in name, pass your own zero-arg function returning a string:

```scheme
(moka-segment (lambda () "hello") #:fg "#89b4fa")
```

### Colors

The `#:colors` hash sets fallbacks for segments you didn't style directly. Per-segment `#:fg` and `#:bg` always win.

```scheme
(hash 'mode-fallback-bg "#585b70" 'mode-fallback-fg "#1e1e2e"
      'git-branch-bg "#a6e3a1" 'git-branch-fg "#1e1e2e"
      'lsp "#89b4fa" 'position "#cba6f7" 'dirty "#f9e2af")
```

## Bufferline

```scheme
(moka-bufferline-configure!
 #:active (moka-buffer-style #:bg "#89b4fa" #:fg "#1e1e2e" #:bubble? #t)
 #:inactive (moka-buffer-style)
 #:mode 'multiple      ;; like Helix's own setting: 'never / 'always / 'multiple
 #:gap 1               ;; spacing between tabs
 #:icons? #t           ;; file icons in tabs
 #:dirty? #t           ;; mark unsaved buffers
 #:dirty-color "#f9e2af"
 #:clickable? #t       ;; click a tab to switch to it
 #:row-offset 0)       ;; rows down from the top

(moka-bufferline-enable!)
```

`moka-buffer-style` takes the same `#:fg`, `#:bg` and `#:bubble?` as segments. `(moka-bufferline-disable!)` turns it off.
