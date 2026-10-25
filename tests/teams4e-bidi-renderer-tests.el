;;; teams4e-bidi-renderer-tests.el --- Real renderer bidi integration -*- lexical-binding: t; -*-

(require 'ert)
(require 'teams4e)
(require 'agent-shell-markdown)

(ert-deftest teams4e-bidi-renderer-keeps-quoted-links-and-clean-copy ()
  (with-temp-buffer
    (teams4e-chat-mode)
    (let ((inhibit-read-only t)
          (teams4e-highlight-code-blocks nil)
          (teams4e-message-direction 'contextual))
      (teams4e--insert-rendered-markdown
       "> [Ada](https://example.test/path) שלום לך מה שלומך?"))
    (goto-char (point-min))
    (should (eq 'right-to-left (current-bidi-paragraph-direction)))
    (search-forward "Ada")
    (should (equal "https://example.test/path" (get-text-property (1- (point)) 'shr-url)))
    (let ((copy (filter-buffer-substring (point-min) (point-max))))
      (should (string-match-p "Ada שלום לך מה שלומך?" copy))
      (should-not (string-match-p "\u200f\\|https://example.test/path" copy)))))

(ert-deftest teams4e-bidi-renderer-leaves-fenced-code-unchanged ()
  (with-temp-buffer
    (teams4e-chat-mode)
    (let ((inhibit-read-only t)
          (teams4e-highlight-code-blocks nil))
      (teams4e--insert-rendered-markdown "```text\nAda שלום לך מה שלומך?\n```"))
    (should-not (string-match-p "\u200f" (buffer-string)))
    (should (string-match-p "Ada שלום לך מה שלומך?" (buffer-string)))))

;;; teams4e-bidi-renderer-tests.el ends here
