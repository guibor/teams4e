;;; msteams.el --- Compatibility entry point for teams4e -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The package was called msteams before its first public release.  Requiring
;; this file loads teams4e and aliases the former Lisp namespace so private
;; configurations can migrate without a flag day.

;;; Code:

(require 'teams4e)

(defun teams4e--install-legacy-aliases ()
  "Alias the former msteams namespace to the current teams4e namespace."
  (mapatoms
   (lambda (new)
     (let ((name (symbol-name new)))
       (when (string-prefix-p "teams4e-" name)
         (let* ((old-name (concat "msteams-" (substring name 8)))
                (old (intern old-name)))
           (when (fboundp new)
             (defalias old new))
           (when (boundp new)
             (let ((old-bound (boundp old))
                   (old-value (and (boundp old) (symbol-value old))))
               (when old-bound (makunbound old))
               (defvaralias old new)
               (when old-bound (set old old-value))))))))))

(teams4e--install-legacy-aliases)
(defalias 'msteams #'teams4e)

(provide 'msteams)

;;; msteams.el ends here
