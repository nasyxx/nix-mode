;;; nix-mode.el --- Major mode for editing Nix expressions

;; Author: Eelco Dolstra
;; Maintainer: Matthew Bauer <mjbauer95@gmail.com>
;; Homepage: https://github.com/matthewbauer/nix-mode
;; Version: 1.1
;; Keywords: nix

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; A major mode for editing Nix expressions (.nix files).  See the Nix manual
;; for more information available at https://nixos.org/nix/manual/.

;;; Code:

(require 'company)
(require 'flycheck)

;; Emacs 24.2 compatability
(unless (fboundp 'setq-local)
  (defmacro setq-local (var val)
    "Set variable VAR to value VAL in current buffer."
    `(set (make-local-variable ',var) ,val)))

;; Syntax coloring

(defun nix-syntax-match-antiquote (limit)
  "Find antiquote within a Nix expression up to LIMIT."
  (let ((pos (next-single-char-property-change (point) 'nix-syntax-antiquote
                                               nil limit)))
    (when (and pos (> pos (point)) (< pos (point-max)))
      (goto-char pos)
      (let ((char (char-after pos)))
        (pcase char
          (`?$
           (forward-char 2))
          (`?}
           (forward-char 1)))
        (set-match-data (list pos (point)))
        t))))

(defconst nix-keywords
  '("if" "then"
    "else" "with"
    "let" "in"
    "rec" "inherit"
    "or"
    ))

(defconst nix-builtins
  '("builtins" "baseNameOf"
    "derivation" "dirOf"
    "false" "fetchTarball"
    "import" "isNull"
    "map" "removeAttrs"
    "toString" "true"))

(defconst nix-warning-keywords
  '("assert" "abort" "throw"))

(defconst nix-re-file-path
  "[a-zA-Z0-9._\\+-]*\\(/[a-zA-Z0-9._\\+-]+\\)+")

(defconst nix-re-url
  "[a-zA-Z][a-zA-Z0-9\\+-\\.]*:[a-zA-Z0-9%/\\?:@&=\\+\\$,_\\.!~\\*'-]+")

(defconst nix-re-bracket-path
  "<[a-zA-Z0-9._\\+-]+\\(/[a-zA-Z0-9._\\+-]+\\)*>")

(defconst nix-re-variable-assign
  "\\<\\([a-zA-Z_][a-zA-Z0-9_'\-\.]*\\)[ \t]*=")

(defconst nix-font-lock-keywords
  `(
    (,(regexp-opt nix-keywords 'symbols) . font-lock-keyword-face)
    (,(regexp-opt nix-warning-keywords 'symbols) . font-lock-warning-face)
    (,(regexp-opt nix-builtins 'symbols) . font-lock-builtin-face)
    (,nix-re-url . font-lock-constant-face)
    (,nix-re-file-path . font-lock-constant-face)
    (,nix-re-variable-assign 1 font-lock-variable-name-face)
    (,nix-re-bracket-path . font-lock-constant-face)
    (nix-syntax-match-antiquote 0 font-lock-preprocessor-face t))
  "Font lock keywords for nix.")

(defvar nix-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?/ ". 14" table)
    (modify-syntax-entry ?* ". 23" table)
    (modify-syntax-entry ?# "< b" table)
    (modify-syntax-entry ?\n "> b" table)
    (modify-syntax-entry ?\" "|" table) ;; let " be opened/closed by antiquotes
    table)
  "Syntax table for Nix mode.")

(defun nix-syntax-propertize-multiline-string ()
  "Set syntax properies for multiline string delimiters."
  (let* ((start (match-beginning 0))
         (context (save-excursion (save-match-data (syntax-ppss start))))
         (string-type (nth 3 context)))

    (pcase string-type

      (`t
       ;; inside a multiline string
       ;; ending multi-line string delimiter
       (put-text-property (1+ start) (+ 2 start)
                          'syntax-table (string-to-syntax "|")))

      (`nil
       ;; beginning multi-line string delimiter
       (put-text-property start (1+ start)
                          'syntax-table (string-to-syntax "|"))))))

(defun nix-syntax-propertize-antiquote ()
  "Set syntax properties for an antiquote mark."
  (let* ((start (match-beginning 0))
         (context (save-excursion (save-match-data (syntax-ppss start))))
         (string-type (nth 3 context)))

    (when string-type ;; only add antiquote when we're already in a string
      (put-text-property start (1+ start)
			 'syntax-table (string-to-syntax "|"))
      (put-text-property start (+ 2 start)
			 'nix-syntax-antiquote t))))

(defun nix-syntax-propertize-close-brace ()
  "Set syntax properties for close braces.
If a close brace `}' ends an antiquote, the next character begins a string."
  (let* ((start (match-beginning 0))
         (context (save-excursion (save-match-data (syntax-ppss start))))
         (open (nth 1 context)))

    (when open ;; a corresponding open-brace was found
      (when (get-text-property open 'nix-syntax-antiquote)
	(put-text-property start (1+ start)
			   'syntax-table (string-to-syntax "|"))
	(put-text-property start (1+ start)
			   'nix-syntax-antiquote t)))))

(defun nix-syntax-propertize-escaped-antiquote ()
  "Set syntax properties for escaped antiquote."
  (let* ((start (match-beginning 0))
         (context (save-excursion (save-match-data (syntax-ppss start))))
         (string-type (nth 3 context)))

    ;; treat like multiline when not already in string
    ;; else ignore
    (when (not string-type)
      (put-text-property start (1+ start)
			 'syntax-table (string-to-syntax "|"))

      (when (string= (buffer-substring (+ 2 start) (+ 4 start)) "${")
	(put-text-property (+ 2 start) (+ 3 start)
			   'syntax-table (string-to-syntax "|"))
	(put-text-property (+ 2 start) (+ 4 start)
			   'nix-syntax-antiquote t))
      )
    ))

(defun nix-syntax-propertize (start end)
  "Special syntax properties for Nix from START to END."
  ;; search for multi-line string delimiters
  (goto-char start)
  (remove-text-properties start end '(syntax-table nil nix-syntax-antiquote nil))
  (funcall
   (syntax-propertize-rules
    ("''['\\$\]" ;; ignore ''* characters
     (0 (ignore (nix-syntax-propertize-escaped-antiquote))))
    ("''"
     (0 (ignore (nix-syntax-propertize-multiline-string))))
    ("\\${"
     (0 (ignore (nix-syntax-propertize-antiquote))))
    ("}"
     (0 (ignore (nix-syntax-propertize-close-brace)))))
   start end))

;;; Flycheck

(defconst nix-err-msg-re
  "error: \\(.*\\) at \\(.*\\):\\([0-9]+\\):\\([0-9]+\\)")

(defun nix--parse-errors (output checker buffer)
  (with-temp-buffer
    (insert output)
    (goto-char (point-min))
    (let ((errs '()))
      (while (search-forward-regexp nix-err-msg-re nil t 1)
        (let* ((file (match-string 2))
               (line (string-to-number (match-string 3)))
               (col (string-to-number (match-string 4)))
               (msg (match-string 1)))
          (setq errs
                (cons (flycheck-error-new-at
                       line col 'error msg
                       :filename (and (not (string= file "(string)")) file)
                       :checker checker
                       :buffer buffer)
                      errs))))
    errs)))

(flycheck-def-args-var flycheck-nix-args (nix))

(flycheck-define-checker nix
  "A syntax and evaluation checker for Nix using nix-instantiate."
  :command ("nix-instantiate" "--eval" "--strict" "--show-trace" (eval flycheck-nix-args) "-")
  :standard-input t
  :error-parser nix--parse-errors
  :modes (nix-mode)
  )

(add-to-list 'flycheck-checkers 'nix)

;;; REPL

(defvar nix-prompt-regexp "nix-repl> ")

(define-derived-mode nix-repl-mode comint-mode "Nix-REPL"
  "Interactive prompt for Nix."
  (setq-local comint-prompt-regexp nix-prompt-regexp)
  (setq-local comint-prompt-read-only t)
  (add-to-list 'company-backends 'company-nix)
  (company-mode))

(defun nix-repl-show ()
  "Load the Nix-REPL."
  (interactive)
  (pop-to-buffer-same-window
   (get-buffer-create "*Nix-REPL*"))
  (unless (comint-check-proc (current-buffer))
    (nix--make-repl-in-buffer (current-buffer))
    (nix-repl-mode)))

(defun nix--make-repl-in-buffer (buffer)
  (make-comint-in-buffer "Nix-REPL" buffer "nix-repl"))

;;; Company

(defun company-nix (command &optional arg &rest ignored)
  (interactive '(interactive))
  (case command
    (interactive (company-begin-backend 'company-nix))
    (prefix (and (member major-mode '(nix-mode nix-repl-mode))
                 (nix-grab-attr-path)))
    (candidates
     (nix-get-completions (get-buffer-process (nix--get-company-buffer)) arg))
    (sorted t)))

(defun nix-grab-attr-path ()
  (if (looking-at "[^a-zA-Z0-9'\\-_\\.]")
      (buffer-substring (point) (save-excursion (skip-chars-backward "a-zA-Z0-9'\\-_\\.")
                                                (point)))
    (unless (and (char-after)
                 (string-match "[a-zA-Z0-9'\\-_]" (char-to-string (char-after)))
                 ""))))

(defun nix--get-company-buffer (&optional buffer)
  (let* ((buf (or buffer (current-buffer)))
         (repl-buf (get-buffer "*Nix-REPL*")))
    (if (or (equal buf "*Nix-REPL*") (equal buf repl-buf))
        repl-buf
      (nix--get-company-backend-buffer buf))))

(defvar nix-company-backend-buffer-name " *nix-company-backend*")
(defvar nix--company-last-buffer nil)

(defun nix--get-company-backend-buffer (buffer)
  (let* ((buf-file (buffer-file-name buffer))
         (backend-buf (get-buffer-create nix-company-backend-buffer-name))
         (last-buf nix--company-last-buffer)
         (proc (get-buffer-process backend-buf)))
    (with-current-buffer buffer
      (if (and proc
               (process-live-p proc))
          (if (not (string= last-buf (buffer-name)))
              (progn (quit-process proc)
                     (nix--make-repl-in-buffer backend-buf)
                     (nix--send-repl (concat ":l " buf-file "\n")
                                     (get-buffer-process backend-buf) t)
                     (setq nix--company-last-buffer (buffer-name)))
            (nix--send-repl ":r\n" proc t))
        (progn (nix--make-repl-in-buffer backend-buf)
               (nix--send-repl (concat ":l " buf-file "\n")
                               (get-buffer-process backend-buf) t)
               (setq nix--company-last-buffer (buffer-name))))
      backend-buf)))

(defun nix-get-completions (proc prefix)
  (save-match-data
    (nix--with-temp-process-filter proc
      (goto-char (point-min))
      (process-send-string proc (concat prefix "\t\"" (nix--char-with-ctrl ?a) "\"\n"))
      (setq i 0)
      (while (and (< (setq i (1+ i)) 100)
                  (not (search-forward-regexp "\"\\([^\"]*\\)\"[\n]*nix-repl>" nil t)))
        (sleep-for 0.01))
      (let ((new-prefix (match-string 1))
            (start-compl (point)))
        (if (string-suffix-p " " new-prefix)
            (list (substring new-prefix 0 -1))
          (process-send-string proc (concat new-prefix "\t\t" (nix--char-with-ctrl ?u) "\n"))
          (goto-char start-compl)
          (setq i 0)
          (while (and (< (setq i (1+ i)) 100)
                      (not (search-forward-regexp
                            "[\n]+nix-repl>\\|Display all \\([0-9]+\\)" nil t)))
            (sleep-for 0.01))
          (if (match-string 1)
              (progn
                (process-send-string proc "n")
                '())
            (search-backward "\n" nil t)
            (split-string (buffer-substring start-compl (1- (point))))))))))

(defun nix--send-repl (input &optional process mute)
  (let ((proc (or process (get-buffer-process (current-buffer)))))
    (if mute
        (nix--with-temp-process-filter proc
          (process-send-string proc input))
      (process-send-string proc input))))

(defun nix--char-with-ctrl (char)
  (char-to-string (logand #b10011111 char)))

(defmacro nix--with-temp-process-filter (proc &rest body)
  (declare (indent defun))
  `(let* ((buf (generate-new-buffer " *temp-process-output*"))
          (proc-filter-saved (process-filter ,proc))
          (proc-marker (with-current-buffer buf (point-marker))))
     (set-process-filter ,proc (nix--process-filter buf proc-marker))
     (unwind-protect
         (with-current-buffer buf
           ,@body)
       (set-process-filter ,proc proc-filter-saved)
       (kill-buffer buf))))

(defun nix--process-filter (buf marker)
  (lambda (proc string)
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (save-excursion
          (goto-char marker)
          (insert string)
          (set-marker marker (point)))))))

;;; Indentation

(defun nix-indent-level-parens ()
  "Find indent level based on parens."
  (save-excursion
    (beginning-of-line)

    (let ((p1 (point))
	  (p2 (nth 1 (syntax-ppss)))
	  (n 0))

      ;; prevent moving beyond buffer
      (if (eq p2 1)
	  (setq n (1+ n)))

      (while (and p2 (not (eq p2 1))) ;; make sure p2 > 1
	(goto-char p2)
	(backward-char)
	(let ((l1 (line-number-at-pos p1))
	      (l2 (line-number-at-pos p2)))
	  (if (not (eq l1 l2))
	      (setq n (1+ n))))
	(setq p1 p2)
	(setq p2 (nth 1 (syntax-ppss)))

	;; make sure we don't go beyond buffer
	(if (eq p2 1)
	    (setq n (1+ n))))

      n)))

(defun nix-indent-level-let ()
  "Get indent level based on # of let statements."
  (save-excursion
    (beginning-of-line)

    (let ((lets 0)
	  (ins 0))
      (while (not (eq (point) (point-min)))
	(forward-line -1)
	(cond
	 ((and
	   (or
	    (looking-at "[[:space:]]*let$")
	    (looking-at "[[:space:]]*let[[:space:]]")
	    (looking-at ".*[[:space:]]let$"))
	   (not
	    (or
	     (looking-at ".*[[:space:]]in$")
	     (looking-at ".*[[:space:]]in[[:space:]]"))))
	  (setq lets (1+ lets)))
	 ((or
	   (looking-at "^in$")
	   (looking-at "^in[[:space:]]")
	   (looking-at "[[:space:]]+in$")
	   (looking-at "[[:space:]]+in[[:space:]]"))
	  (setq ins (1+ ins)))))

      (- lets ins))))

(defun nix-indent-level-is-closing ()
  "Go forward from beginning of line."
  (save-excursion
    (beginning-of-line)
    (skip-chars-forward "[:space:]")

    (or ;; any of these should -1 indent level
     (looking-at ")")
     (looking-at "}")
     (looking-at "]")
     (looking-at "''")
     (looking-at ",")
     (looking-at "in[[:space:]]")
     (looking-at "in$"))))

(defun nix-indent-level-is-hanging ()
  "Is hanging?"
  (save-excursion
    (beginning-of-line)
    (skip-chars-forward "[:space:]")

    (forward-line -1)
    (end-of-line)
    (skip-chars-backward "\n[:space:]")

    ;; skip through any comments in the way
    (while (nth 4 (syntax-ppss))
      (goto-char (nth 8 (syntax-ppss)))
      (skip-chars-backward "\n[:space:]"))

    (or
     (looking-back "=" 1)
     (looking-back "+" 1)
     ;; (looking-back ":" 1)
     (looking-back "//" 1))))

(defun nix-indent-level ()
  "Get current indent level."
  (* tab-width (+
		(nix-indent-level-parens)
		(nix-indent-level-let)
		(if (nix-indent-level-is-closing) -1
		  (if (nix-indent-level-is-hanging) 1 0)))))

(defun nix-indent-line ()
  "Indent current line in a Nix expression."
  (interactive)
  (cond

   ;; comment
   ((save-excursion
      (beginning-of-line)
      (nth 4 (syntax-ppss))) nil)

   ;; string
   ((save-excursion
      (beginning-of-line)
      (nth 3 (syntax-ppss))) nil)

   ;; else
   (t
    (indent-line-to (nix-indent-level)))))

;; Visit file

(defun nix-visit-file ()
  "Go to file under cursor."
  (interactive)
  (save-excursion
    (forward-whitespace -1)
    (skip-chars-forward " \t")
    (if (looking-at nix-re-file-path)
	(find-file (match-string-no-properties 0)))))

;; Formatting

(defcustom nix-nixfmt-bin "nixfmt"
  "Path to nixfmt executable."
  :group 'nix
  :type 'string)

(defun nix--format-call (buf)
  "Format BUF using nixfmt."
  (with-current-buffer (get-buffer-create "*nixfmt*")
    (erase-buffer)
    (insert-buffer-substring buf)
    (if (zerop (call-process-region (point-min) (point-max) nix-nixfmt-bin t t nil))
        (progn
          (if (not (string= (buffer-string) (with-current-buffer buf (buffer-string))))
              (copy-to-buffer buf (point-min) (point-max)))
          (kill-buffer))
      (error "Nixfmt failed, see *nixfmt* buffer for details"))))

(defun nix-format-buffer ()
  "Format the current buffer using nixfmt."
  (interactive)
  (unless (executable-find nix-nixfmt-bin)
    (error "Could not locate executable \"%s\"" nix-nixfmt-bin))
  (nix--format-call (current-buffer))
  (message "Formatted buffer with rustfmt."))

;; Key maps

(defvar nix-mode-menu (make-sparse-keymap "Nix")
  "Menu for Nix mode.")

(defvar nix-mode-map (make-sparse-keymap)
  "Local keymap used for Nix mode.")

(defun nix-create-keymap ()
  "Create the keymap associated with the Nix mode."
  (define-key nix-mode-map "\C-c\C-f" 'nix-visit-file)
  (define-key nix-mode-map "\C-c\C-r" 'nix-format-buffer))

(defun nix-create-menu ()
  "Create the Nix menu as shown in the menu bar."
  (let ((m '("Nix"
	     ["Goto file" nix-visit-file t]
	     ["Format buffer" nix-format-buffer t])
	   ))
    (easy-menu-define ada-mode-menu nix-mode-map "Menu keymap for Nix mode" m)))

(nix-create-keymap)
(nix-create-menu)

;;;###autoload
(define-derived-mode nix-mode prog-mode "Nix"
  "Major mode for editing Nix expressions.

The following commands may be useful:

  '\\[newline-and-indent]'
    Insert a newline and move the cursor to align with the previous
    non-empty line.

  '\\[fill-paragraph]'
    Refill a paragraph so that all lines are at most `fill-column'
    lines long.  This should do the right thing for comments beginning
    with `#'.  However, this command doesn't work properly yet if the
    comment is adjacent to code (i.e., no intervening empty lines).
    In that case, select the text to be refilled and use
    `\\[fill-region]' instead.

The hook `nix-mode-hook' is run when Nix mode is started.

\\{nix-mode-map}
"
  (set-syntax-table nix-mode-syntax-table)

  ;; Disable hard tabs and set tab to 2 spaces
  ;; Recommended by nixpkgs manual: https://nixos.org/nixpkgs/manual/#sec-syntax
  (setq-local indent-tabs-mode nil)
  (setq-local tab-width 2)

  ;; Font lock support.
  (setq-local font-lock-defaults '(nix-font-lock-keywords nil nil nil nil))

  ;; Special syntax properties for Nix
  (setq-local syntax-propertize-function 'nix-syntax-propertize)

  ;; Look at text properties when parsing
  (setq-local parse-sexp-lookup-properties t)

  ;; Automatic indentation [C-j]
  (setq-local indent-line-function 'nix-indent-line)

  ;; Indenting of comments
  (setq-local comment-start "# ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "\\(^\\|\\s-\\);?#+ *")
  (setq-local comment-multi-line t)

  ;; Filling of comments
  (setq-local adaptive-fill-mode t)
  (setq-local paragraph-start "[ \t]*\\(#+[ \t]*\\)?$")
  (setq-local paragraph-separate paragraph-start)

  (easy-menu-add nix-mode-menu nix-mode-map)

  ;; Flycheck
  (flycheck-select-checker 'nix)
  (flycheck-mode)

  ;; Company
  (add-to-list 'company-backends 'company-nix)
  (company-mode))

;;;###autoload
(progn
  (add-to-list 'auto-mode-alist '("\\.nix\\'" . nix-mode))
  (add-to-list 'auto-mode-alist '("\\.nix.in\\'" . nix-mode)))

(defun nix-mode-reload ()
  "Reload Nix mode."
  (interactive)
  (unload-feature 'nix-mode)
  (require 'nix-mode)
  (nix-mode))

(provide 'nix-mode)

;;; nix-mode.el ends here
