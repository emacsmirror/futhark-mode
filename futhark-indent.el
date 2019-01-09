;;; futhark-indent.el --- automatic indentation for futhark-mode  -*- lexical-binding: t; -*-

;; Copyright (C) DIKU 2013-2019, University of Copenhagen
;;
;; URL: https://github.com/diku-dk/futhark-mode
;; Keywords: languages
;; Version: 0.2
;; Package-Requires: ((emacs "24.3") (cl-lib "0.5"))

;; This file is not part of GNU Emacs.

;;; License:
;; ICS <https://github.com/diku-dk/futhark-mode/blob/master/LICENSE>

;;; Commentary:
;; See futhark-mode.el.

;;; Code:

(require 'smie) ; built-in
(require 'cl-lib)


(defconst futhark-indent-level 2
  "The basic indent level for `futhark-mode'.")


;;; Lexer:

(defun futhark-indent-symbol (word)
  "Add blanks around WORD."
  (concat "\\<" word "\\>"))

(defun futhark-indent-looking-back-at (word)
  "Do the same as `looking-at', but move one token back before checking for WORD."
  (save-excursion
    (futhark-indent-backward-token-base)
    (looking-at word)))

(defun futhark-indent-is-empty-line ()
  "Check if the line of the current point is empty.
It is considered empty if the line consists of zero or more
whitespace characters."
  (save-excursion
    (forward-line 0)
    (or (looking-at "[[:space:]]*\n")
        (looking-at "[[:space:]]*$"))))

(defun futhark-indent-max (&rest args)
  "Like `max', but also accepts nil values in ARGS."
  (let ((args-nonnil (cl-remove-if-not 'identity args)))
    (if args-nonnil
        (apply 'max args-nonnil)
      nil)))

(defun futhark-indent-column-of (p)
  "Get the column of point P."
  (when p
    (save-excursion
      (goto-char p)
      (current-column))))

(defmacro futhark-indent-try (func)
  "Try to use FUNC, but go back to the point in START on nil return."
  `(or (,func) (progn (goto-char start) nil)))

(defun futhark-indent-forward-token-base ()
  "Find the next Futhark token, if any."
  (forward-comment (point-max))
  (buffer-substring-no-properties
   (point)
   (progn (or (/= 0 (skip-syntax-forward "w_")) ; variables, keywords
              (skip-syntax-forward ".")) ; operators, keywords
          (point))))

(defun futhark-indent-backward-token-base ()
  "Find the previous Futhark token, if any."
  (forward-comment (- (point)))
  (buffer-substring-no-properties
   (point)
   (progn (or (/= 0 (skip-syntax-backward "w_"))
              (skip-syntax-backward "."))
          (point))))


;; Lexer extension: Support 'let' chains with the 'in's left out.  Operator
;; precedence grammars are quite limited, but we still want to be able to
;; express these very typical cases properly.  It is easy to write a grammar
;; rule for function bodies like
;;
;;   let x = 0 in
;;   let y = 1 in
;;   ...
;;
;; but it is impossible for function bodies like
;;
;;   let x = 0
;;   let y = 0
;;   ...
;;
;; where the intermediate 'in's are implicit.  We solve this by using the empty
;; space just prior to 'let' as the 'in-implicit' token.  There will always be
;; at least `futhark-indent-level' empty spaces, since this only needs to
;; work on non-top-level 'let's.

(defun futhark-indent-forward-token-in-implicit ()
  "Find the next token."
  (when (looking-at "  let") ; currently on the 'in-implicit' token.
    ;; Normalise the point position.
    (futhark-indent-backward-token-base)
    (futhark-indent-forward-token-base))
  (if (not (or (futhark-indent-looking-back-at "=")
               (futhark-indent-looking-back-at "->")
               (futhark-indent-looking-back-at (futhark-indent-symbol "in"))
               (futhark-indent-looking-back-at (futhark-indent-symbol "then"))
               (futhark-indent-looking-back-at (futhark-indent-symbol "else"))
               (futhark-indent-looking-back-at (futhark-indent-symbol "do"))
               (futhark-indent-looking-back-at (futhark-indent-symbol "unsafe"))
               (save-excursion
                 (forward-line 0)
                 (looking-at "[^{\n]*{[[:space:]]*$"))
               (futhark-indent-is-empty-line)
               (save-excursion
                 (forward-line 1)
                 (futhark-indent-is-empty-line))
               (looking-at " ")))
      (let ((found (futhark-indent-forward-token-base)))
        (and (equal found "let")
             (progn (goto-char (- (point) 4))
                    t)
             (looking-at " ")
             "in-implicit"))))

(defun futhark-indent-backward-token-in-implicit ()
  "Find the previous token."
  (when (looking-at " let")
    (futhark-indent-forward-token-base)
    (futhark-indent-backward-token-base))
  (if (looking-at (futhark-indent-symbol "let"))
      (let ((let-point (point))
            (found (futhark-indent-backward-token-base)))
        (and (not (or (equal found "=")
                      (equal found "->")
                      (equal found "in")
                      (equal found "then")
                      (equal found "else")
                      (equal found "do")
                      (equal found "unsafe")
                      (save-excursion
                        (forward-line 0)
                        (looking-at "[^{\n]*{[[:space:]]*$"))
                      (futhark-indent-is-empty-line)
                      (save-excursion
                        (forward-line 1)
                        (futhark-indent-is-empty-line))))
             (progn (goto-char (- let-point 2))
                    t)
             (looking-at " ")
             "in-implicit"))))


;; Lexer extension: Introduce a special token for when we believe 'let' to be a
;; top-level 'let'.  We currently embed the heuristic that if the previous
;; non-comment line is blank, or if it is the first declaration inside a module,
;; then it is top-level (which is a pretty poor way of checking it).

(defun futhark-indent-forward-token-toplevel-let ()
  "Find the next token."
  (let ((found (futhark-indent-forward-token-base)))
    (when (and (equal found "let")
               (or (save-excursion
                     (forward-line -1)
                     (or (futhark-indent-is-empty-line)
                         (looking-at "[^{\n]*{[[:space:]]*$")))
                   (save-excursion
                     (futhark-indent-backward-token-base)
                     (let ((line (line-number-at-pos)))
                       (forward-comment (- (point)))
                       (and (/= line (line-number-at-pos))
                            (progn (forward-line 1) t)
                            (futhark-indent-is-empty-line))))
                   (= (line-number-at-pos (point)) 1)))
      "toplevel-let")))

(defun futhark-indent-backward-token-toplevel-let ()
  "Find the previous token."
  (let ((found (futhark-indent-backward-token-base)))
    (when (and (equal found "let")
               (or (save-excursion
                     (forward-line -1)
                     (or (futhark-indent-is-empty-line)
                         (looking-at "[^{\n]*{[[:space:]]*$")))
                   (save-excursion
                     (let ((line (line-number-at-pos)))
                       (forward-comment (- (point)))
                       (and (/= line (line-number-at-pos))
                            (progn (forward-line 1) t)
                            (futhark-indent-is-empty-line))))
                   (= (line-number-at-pos (point)) 1)))
      "toplevel-let")))


(defun futhark-indent-forward-token ()
  "Find the next Futhark token, if any."
  (let ((start (point)))
    (or (futhark-indent-try futhark-indent-forward-token-in-implicit)
        (futhark-indent-try futhark-indent-forward-token-toplevel-let)
        (futhark-indent-forward-token-base))))

(defun futhark-indent-backward-token ()
  "Find the previous Futhark token, if any."
  (let ((start (point)))
    (or (futhark-indent-try futhark-indent-backward-token-in-implicit)
        (futhark-indent-try futhark-indent-backward-token-toplevel-let)
        (futhark-indent-backward-token-base))))

(defmacro futhark-indent-first-token (func-token func-sexp)
  "Go to the first token through FUNC-TOKEN and FUNC-SEXP.
Return its point."
  `(save-excursion
    (let ((cur (point))
          (found nil))
      (while (and cur (not found))
        (let ((found-cur (,func-token)))
          (cond ((equal found-cur token)
                 (setq found t))
                ((equal found-cur "")
                 (ignore-errors (,func-sexp 1) t))))
        (setq cur (if (= (point) cur) nil (point))))
      (when found (point)))))

(defun futhark-indent-first-backward-token (token)
  "Go to the first token TOKEN before the current position, if it exists.
Return its point."
  (futhark-indent-first-token futhark-indent-backward-token backward-sexp))

(defun futhark-indent-first-forward-token (token)
  "Go to the first token TOKEN after the current position, if it exists.
Return its point."
  (futhark-indent-first-token futhark-indent-forward-token forward-sexp))

(defun futhark-indent-find-outer-module ()
  "Try to find the 'module' or 'open' enclosing the current code block."
  (save-excursion
    (ignore-errors (backward-up-list 1) t)
    (when (or (looking-at "{") (looking-at "("))
      (futhark-indent-max
       (futhark-indent-column-of (futhark-indent-first-backward-token "module"))
       (futhark-indent-column-of (futhark-indent-first-backward-token "open"))

       ;; We need to go two levels up in case of functors like
       ;;
       ;;   module foo = bar({ ... })
       (and
        (equal (futhark-indent-backward-token) "")
        (ignore-errors (backward-up-list 1) t)
        (futhark-indent-max
         (futhark-indent-column-of (futhark-indent-first-backward-token "module"))
         (futhark-indent-column-of (futhark-indent-first-backward-token "open"))))))))


;;; Grammar for the SMIE parser:

(defconst futhark-indent-grammar
  (smie-prec2->grammar
   (smie-merge-prec2s

    ;; The main grammar.
    (smie-bnf->prec2
     '(
       (id)
       (types (type)
              (type "," type))
       (type (id)
             ("(" types ")")
             ("{" params "}")
             (type "|" type))
       (param (id)
              (id ":" type))
       (params (param)
               (params "," params))
       (pat (param)
            ("(" params ")"))
       (pats)
       (match-case (exp "->" exp))
       (match-cases (match-case)
                    (match-case "case" match-case))
       (exps (exp)
             (exp "," exp))
       (record-assignment (id "=" exp))
       (record-assignments (record-assignment)
                           (record-assignment "," record-assignment))
       (exp (id)
            ("[" exps "]")
            ("{" record-assignments "}")
            ("unsafe" exp)
            ("\\" pats "->" exp)
            ("let" pat "=" exp "in" exp)
            ;; SMIE gets less confused if we leave out the final 'exp'
            ;; non-terminal after the 'in-implicit' token (probably because we
            ;; use empty space as a token).  This means that the body expression
            ;; of a function gets parsed into a *series of* expressions, but
            ;; there is still enough structure to properly indent -- extra
            ;; bindings in a let chain don't change the overall picture.
            ("let" pat "=" exp "in-implicit")
            ("if" exp "then" exp "else" exp)
            ("loop" pat "for" exp "do" exp)
            ("loop" pat "=" exp "for" exp "do" exp)
            ("loop" pat "while" exp "do" exp)
            ("loop" pat "=" exp "while" exp "do" exp)
            ("match" exp "case" match-cases)
            )

       ;; We describe the declarations in terms of separators, not
       ;; openers/closers.  SMIE's operator precedence grammar engine gets less
       ;; confused this way.
       (decls (decls "entry" decls)
              (decls "toplevel-let" decls)
              (decls "type" decls)
              (decls "val" decls)
              (decls "include" decls)
              (decls "import" decls)
              (decls "module" decls)
              (decls "open" decls)
              (decls "local" decls)))

     ;; Resolve conflicts (poorly): If more than one relation exists between two
     ;; tokens (i.e., a shift/reduce conflict), just collapse the relations into
     ;; a single '=' relation (i.e., shift).
     '((assoc "entry" "toplevel-let" "type" "val" "include" "import" "module" "open" "local"))
     '((assoc "," "|" "case" "->"))
     )

    ;; Basic operator precedences.
    (smie-precs->prec2
     '((nonassoc "->")
       (assoc "|>")
       (assoc "<|")
       (assoc "||")
       (assoc "&&")
       (assoc "<=" ">=" ">" "<" "==" "!=")
       (assoc "&" "^" "|")
       (assoc "<<" ">>")
       (assoc "+" "-")
       (assoc "*" "/" "%" "//" "%%")
       (assoc "**")))
    ))
  "The simplified Futhark grammar.")


;;; Extra indentation rules to supplement the grammar-generated ones:

(defun futhark-indent-rules (kind token)
  "The SMIE rules for indentation.  See SMIE documentation for info on KIND and TOKEN."
  (pcase (cons kind token)
    (`(:elem . basic) futhark-indent-level)
    (`(:elem . args) 0)

    (`(:after . "in")
     (smie-rule-parent))

    ;; Indent the following line one level.  This is a bit hacky because of our
    ;; declarations-as-separators grammar rules.
    (`(:after . "=")
     (unless (smie-rule-parent-p "loop")
       (let ((base (futhark-indent-max
                    (futhark-indent-first-backward-token "toplevel-let")
                    (futhark-indent-first-backward-token "let")
                    (futhark-indent-first-backward-token "entry"))))
         (when base
           ;; In the case of 'local let ...' lines, indent relative to 'local',
           ;; not 'let'.
           (let* ((base-local
                   (save-excursion
                     (goto-char base)
                     (when (equal (futhark-indent-backward-token) "local") (point))))
                  (base (or base-local base)))
             `(column . ,(+ (futhark-indent-column-of base) futhark-indent-level)))))))

    (`(:before . "in-implicit")
     (save-excursion
       (ignore-errors (backward-sexp 1) t)
       (when (looking-at (futhark-indent-symbol "let"))
         `(column . ,(current-column)))))

    (`(:before . ,(or "entry" "type" "val"
                      "include" "import" "module" "open" "local"))
     (when (smie-rule-bolp)
       (let ((outer (futhark-indent-find-outer-module)))
         `(column . ,(if outer (+ outer futhark-indent-level) 0)))))

    ;; Even when our heuristic has designated a 'let' as a top-level 'let', it
    ;; might still be wrong.  We disable auto-indentation and let the user
    ;; decide manually.
    (`(:before . "toplevel-let")
     `(column . ,(current-column)))

    (`(:after . ,(or "then" "else" "do"))
     (when (smie-rule-next-p "let") ; waste a little less indentation in these
                                    ; special cases
       (smie-rule-parent)))

    (`(:after . "unsafe") ; indent next token directly under 'unsafe'
     `(column . ,(current-column)))

    (`(:before . ",")
     (when (smie-rule-bolp)
       (smie-rule-parent)))

    (`(:after . ":") ; functors
     (smie-rule-parent futhark-indent-level))

    ;; Handle long 'val' declarations by disabling auto-indentation.
    (`(:before . "->")
     (when (smie-rule-bolp)
       (let ((valp (futhark-indent-first-backward-token "val")))
         (when (and valp
                    (> valp (or (futhark-indent-first-backward-token "\\") 0))
                    (> valp (or (futhark-indent-first-backward-token "case") 0)))
           `(column . (current-column))))))

    (`(:after . "->")
     (cond ((smie-rule-parent-p "\\") ; lambdas
            futhark-indent-level)
           ((save-excursion ; case expressions
              (futhark-indent-backward-token)
              (equal (futhark-indent-backward-token) "case"))
            (save-excursion
              (futhark-indent-backward-token)
              (futhark-indent-backward-token)
              `(column . ,(+ (current-column) futhark-indent-level))))))

    (`(:before . "if")
     (and
      (smie-rule-bolp)
      (smie-rule-parent-p "if")
      (smie-rule-parent)))

    (`(:before . ,(or "then" "else")) ; indent relative to 'else if' chains
     (save-excursion
       (and
        (smie-rule-bolp)
        (progn (futhark-indent-forward-token)
               (ignore-errors (backward-sexp 1) t) t)
        (looking-at (futhark-indent-symbol "if"))
        (equal (futhark-indent-backward-token) "else")
        -5))) ; length of 'else ' (relative un-indent)

    (`(:before . "|") ; in type constructor definitions
     (let ((p (and (smie-rule-bolp)
                   (progn (futhark-indent-backward-token)
                          (looking-at "#"))
                   (futhark-indent-first-backward-token "="))))
       (when p `(column . ,(futhark-indent-column-of p)))))

    (`(:before . "case")
     `(column . ,(futhark-indent-max (futhark-indent-column-of
                                    (futhark-indent-first-backward-token "match"))
                                   (futhark-indent-column-of
                                    (futhark-indent-first-backward-token "case")))))))

(defun futhark-indent-line-basic ()
  "Try to indent the current line.
Handles edge cases where SMIE fails.  SMIE will not re-indent these indented lines."
  (forward-line 0)
  (skip-chars-forward " \t")
  (let* ((cur-col (current-column))
        (indent
         (cond
          ;; Align closing '}' to 'module'/'open', and not directly to the
          ;; matching '{' (as SMIE would seemingly have it).
          ((looking-at "}")
           (futhark-indent-find-outer-module))

          ;; If both the current and previous line is empty (at most
          ;; whitespace), indent optimally w.r.t. top-level constructs, as it is
          ;; likely one of those come next.
          ((and (futhark-indent-is-empty-line)
                (save-excursion
                  (forward-line -1)
                  (futhark-indent-is-empty-line)))
           (let ((outer (futhark-indent-find-outer-module)))
             (if outer (+ outer futhark-indent-level) 0)))

          ;; Indent a '}'-subsequent line relative to the '}' symbol.
          ((save-excursion
             (forward-line -1)
             (looking-at "[[:space:]]*}[[:space:]]*$"))
           (save-excursion
             (forward-line -1)
             (skip-syntax-forward " \t")
             (current-column)))

          ;; Align comment to next non-comment line.
          ((looking-at comment-start)
           (save-excursion
             (forward-comment (count-lines (point-min) (point)))
             (current-column))
           )

          ;; Work around the limitations of the 'in-implicit' token: If the user
          ;; has (temporarily) removed all indentation in front of a 'let'
          ;; token, there is no empty space for the implicit 'in' token.  In
          ;; this edge case we force the insertion of spaces, and leave the
          ;; heavy lifting to SMIE.
          ((and (equal "let" (save-excursion
                               (futhark-indent-forward-token)))
                (save-excursion
                  (forward-line 0)
                  (looking-at "[[:space:]]?let\\>")))
           (save-excursion
             (forward-line 0)
             (insert "  ")
             nil))

          ;; Use a simpler default than SMIE for where to start the new line.
          ;; SMIE likes to assume that we want to keep adding terms to a
          ;; previous expression if one exists, but it is more common to want to
          ;; make a new binding.  This only affects the default position on an
          ;; *empty* line, and only if that empty line has a very specific
          ;; context; if the programmer writes something else than a new
          ;; binding, that will also be indented correctly.
          ((and (futhark-indent-is-empty-line)
                (save-excursion
                  (forward-line -1)
                  (member (futhark-indent-forward-token) '("in-implicit" "let")))
                (save-excursion
                  (not (equal "=" (futhark-indent-backward-token)))))
           (futhark-indent-column-of (futhark-indent-first-backward-token "let")))

          ;; Do not auto-indent multi-line function parameters.
          (t
           (let ((cur (point))
                 (function-start (futhark-indent-max
                                  (futhark-indent-first-backward-token "toplevel-let")
                                  (futhark-indent-first-backward-token "entry"))))
             (when function-start
               (save-excursion
                 (goto-char function-start)
                 (let ((first-eq (futhark-indent-first-forward-token "=")))
                   (when (and first-eq
                              (< cur first-eq))
                     cur-col)))))))))
    (when indent
      (progn (indent-line-to indent) t))))

(defun futhark-indent-line ()
  "Indent the current line.
Puts an extra layer of hacks in front of SMIE."
  (let ((start (point)))
    (or (futhark-indent-try futhark-indent-line-basic)
        (smie-indent-line))))

(defun futhark-indent-setup ()
  "Setup Emacs' Simple Minded Indentation Engine for Futhark."
  (smie-setup futhark-indent-grammar #'futhark-indent-rules
              :backward-token #'futhark-indent-backward-token
              :forward-token #'futhark-indent-forward-token)
  (setq-local indent-line-function 'futhark-indent-line))

(provide 'futhark-indent)

;;; futhark-indent.el ends here