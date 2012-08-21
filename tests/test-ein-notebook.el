(eval-when-compile (require 'cl))
(require 'ert)

(when load-file-name
  (add-to-list 'load-path
               (concat (file-name-directory load-file-name) "mocker")))
(require 'mocker)

(require 'ein-notebook)


;; Test utils

(defvar eintest:notebook-data-simple-json
  "{
 \"metadata\": {
  \"name\": \"Untitled0\"
 },
 \"name\": \"Untitled0\",
 \"nbformat\": 2,
 \"worksheets\": [
  {
   \"cells\": [
    {
     \"cell_type\": \"code\",
     \"collapsed\": false,
     \"input\": \"1 + 1\",
     \"language\": \"python\",
     \"outputs\": [
      {
       \"output_type\": \"pyout\",
       \"prompt_number\": 1,
       \"text\": \"2\"
      }
     ],
     \"prompt_number\": 1
    }
   ]
  }
 ]
}
")


(defun eintest:notebook-from-json (json-string &optional notebook-id)
  (unless notebook-id (setq notebook-id "NOTEBOOK-ID"))
  (flet ((pop-to-buffer (buf) buf)
         (ein:notebook-start-kernel (notebook)))
    (let ((notebook (ein:notebook-new "DUMMY-URL" notebook-id)))
      (setf (ein:$notebook-kernel notebook)
            (ein:kernel-new 8888 "/kernels" (ein:$notebook-events notebook)))
      (ein:notebook-request-open-callback
       notebook :data (ein:json-read-from-string json-string))
      (ein:notebook-buffer notebook))))

(defun eintest:notebook-make-data (cells &optional name)
  (unless name (setq name "Dummy Name"))
  `((metadata . ((name . ,name)))
    (nbformat . 2)
    (name . ,name)
    (worksheets . [((cells . ,(apply #'vector cells)))])))

(defun eintest:notebook-make-empty (&optional name notebook-id)
  "Make empty notebook and return its buffer."
  (eintest:notebook-from-json
   (json-encode (eintest:notebook-make-data nil name)) notebook-id))

(defun eintest:notebook-enable-mode (buffer)
  (with-current-buffer buffer (ein:notebook-plain-mode) buffer))

(defun eintest:kernel-fake-execute-reply (kernel msg-id execution-count)
  (let* ((payload nil)
         (content (list :execution_count 1 :payload payload))
         (packet (list :header (list :msg_type "execute_reply")
                       :parent_header (list :msg_id msg-id)
                       :content content)))
    (ein:kernel--handle-shell-reply kernel (json-encode packet))))

(defun eintest:kernel-fake-stream (kernel msg-id data)
  (let* ((content (list :data data
                        :name "stdout"))
         (packet (list :header (list :msg_type "stream")
                       :parent_header (list :msg_id msg-id)
                       :content content)))
    (ein:kernel--handle-iopub-reply kernel (json-encode packet))))

(defun eintest:check-search-forward-from (start string &optional null-string)
  "Search STRING from START and check it is found.
When non-`nil' NULL-STRING is given, it is searched from the
position where the search of the STRING ends and check that it
is not found."
  (save-excursion
    (goto-char start)
    (should (search-forward string nil t))
    (when null-string
      (should-not (search-forward null-string nil t)))))

(defun eintest:cell-check-output (cell regexp)
  (save-excursion
    (goto-char (ein:cell-location cell :after-input))
    (should (looking-at-p (concat "\\=" regexp "\n")))))


;; from-json

(ert-deftest ein:notebook-from-json-simple ()
  (with-current-buffer (eintest:notebook-from-json
                        eintest:notebook-data-simple-json)
    (should (ein:$notebook-p ein:%notebook%))
    (should (equal (ein:$notebook-notebook-id ein:%notebook%) "NOTEBOOK-ID"))
    (should (equal (ein:$notebook-notebook-name ein:%notebook%) "Untitled0"))
    (should (equal (ein:worksheet-ncells ein:%worksheet%) 1))
    (let ((cell (car (ein:worksheet-get-cells ein:%worksheet%))))
      (should (ein:codecell-p cell))
      (should (equal (oref cell :input) "1 + 1"))
      (should (equal (oref cell :input-prompt-number) 1))
      (let ((outputs (oref cell :outputs)))
        (should (equal (length outputs) 1))
        (let ((o1 (car outputs)))
          (should (equal (plist-get o1 :output_type) "pyout"))
          (should (equal (plist-get o1 :prompt_number) 1))
          (should (equal (plist-get o1 :text) "2")))))))

(ert-deftest ein:notebook-from-json-empty ()
  (with-current-buffer (eintest:notebook-make-empty)
    (should (ein:$notebook-p ein:%notebook%))
    (should (equal (ein:$notebook-notebook-id ein:%notebook%) "NOTEBOOK-ID"))
    (should (equal (ein:$notebook-notebook-name ein:%notebook%) "Dummy Name"))
    (should (equal (ein:worksheet-ncells ein:%worksheet%) 0))))


;; Notebook commands

(ert-deftest ein:notebook-insert-cell-below-command-simple ()
  (with-current-buffer (eintest:notebook-make-empty)
    (call-interactively #'ein:worksheet-insert-cell-below)
    (call-interactively #'ein:worksheet-insert-cell-below)
    (call-interactively #'ein:worksheet-insert-cell-below)
    (should (equal (ein:worksheet-ncells ein:%worksheet%) 3))))

(ert-deftest ein:notebook-insert-cell-above-command-simple ()
  (with-current-buffer (eintest:notebook-make-empty)
    (call-interactively #'ein:worksheet-insert-cell-above)
    (call-interactively #'ein:worksheet-insert-cell-above)
    (call-interactively #'ein:worksheet-insert-cell-above)
    (should (equal (ein:worksheet-ncells ein:%worksheet%) 3))))

(ert-deftest ein:notebook-delete-cell-command-simple ()
  (with-current-buffer (eintest:notebook-make-empty)
    (loop repeat 3
          do (call-interactively #'ein:worksheet-insert-cell-above))
    (should (equal (ein:worksheet-ncells ein:%worksheet%) 3))
    (loop repeat 3
          do (call-interactively #'ein:worksheet-delete-cell))
    (should (equal (ein:worksheet-ncells ein:%worksheet%) 0))))

(ert-deftest ein:notebook-delete-cell-command-no-undo ()
  (with-current-buffer (eintest:notebook-make-empty)
    (call-interactively #'ein:worksheet-insert-cell-above)
    (insert "some text")
    (should (equal (buffer-string) "
In [ ]:
some text

"))
    (call-interactively #'ein:worksheet-delete-cell)
    (should (equal (buffer-string) "\n"))
    (should-error (undo))               ; should be ignore-error?
    (should (equal (buffer-string) "\n"))))

(ert-deftest ein:notebook-kill-cell-command-simple ()
  (with-current-buffer (eintest:notebook-make-empty)
    (let (ein:kill-ring ein:kill-ring-yank-pointer)
      (loop repeat 3
            do (call-interactively #'ein:worksheet-insert-cell-above))
      (should (equal (ein:worksheet-ncells ein:%worksheet%) 3))
      (loop for i from 1 to 3
            do (call-interactively #'ein:worksheet-kill-cell)
            do (should (equal (length ein:kill-ring) i))
            do (should (equal (ein:worksheet-ncells ein:%worksheet%) (- 3 i)))))))

(ert-deftest ein:notebook-copy-cell-command-simple ()
  (with-current-buffer (eintest:notebook-make-empty)
    (let (ein:kill-ring ein:kill-ring-yank-pointer)
      (loop repeat 3
            do (call-interactively #'ein:worksheet-insert-cell-above))
      (should (equal (ein:worksheet-ncells ein:%worksheet%) 3))
      (loop repeat 3
            do (call-interactively #'ein:worksheet-copy-cell))
      (should (equal (ein:worksheet-ncells ein:%worksheet%) 3))
      (should (equal (length ein:kill-ring) 3)))))

(ert-deftest ein:notebook-yank-cell-command-simple ()
  (with-current-buffer (eintest:notebook-make-empty)
    (let (ein:kill-ring ein:kill-ring-yank-pointer)
      (loop repeat 3
            do (call-interactively #'ein:worksheet-insert-cell-above))
      (should (equal (ein:worksheet-ncells ein:%worksheet%) 3))
      (loop repeat 3
            do (call-interactively #'ein:worksheet-kill-cell))
      (should (equal (ein:worksheet-ncells ein:%worksheet%) 0))
      (should (equal (length ein:kill-ring) 3))
      (loop repeat 3
            do (call-interactively #'ein:worksheet-yank-cell))
      (should (equal (ein:worksheet-ncells ein:%worksheet%) 3))
      (loop for cell in (ein:worksheet-get-cells ein:%worksheet%)
            do (should (ein:codecell-p cell))
            do (should (slot-boundp cell :kernel))
            do (should (slot-boundp cell :events))))))

(ert-deftest ein:notebook-yank-cell-command-two-buffers ()
  (let (ein:kill-ring ein:kill-ring-yank-pointer)
    (with-current-buffer (eintest:notebook-make-empty "NB1")
      (call-interactively #'ein:worksheet-insert-cell-above)
      (should (equal (ein:worksheet-ncells ein:%worksheet%) 1))
      (call-interactively #'ein:worksheet-kill-cell)
      (should (equal (ein:worksheet-ncells ein:%worksheet%) 0))
      (flet ((y-or-n-p (&rest ignore) t)
             (ein:notebook-del (&rest ignore)))
        ;; FIXME: are there anyway to skip confirmation?
        (kill-buffer)))
    (with-current-buffer (eintest:notebook-make-empty "NB2")
      (call-interactively #'ein:worksheet-yank-cell)
      (should (equal (ein:worksheet-ncells ein:%worksheet%) 1)))))

(ert-deftest ein:notebook-toggle-cell-type-simple ()
  (with-current-buffer (eintest:notebook-make-empty)
    (call-interactively #'ein:worksheet-insert-cell-above)
    (insert "some text")
    (should (ein:codecell-p (ein:worksheet-get-current-cell)))
    (should (slot-boundp (ein:worksheet-get-current-cell) :kernel))
    ;; toggle to markdown
    (call-interactively #'ein:worksheet-toggle-cell-type)
    (should (ein:markdowncell-p (ein:worksheet-get-current-cell)))
    (should (looking-back "some text"))
    ;; toggle to code
    (call-interactively #'ein:worksheet-toggle-cell-type)
    (should (ein:codecell-p (ein:worksheet-get-current-cell)))
    (should (slot-boundp (ein:worksheet-get-current-cell) :kernel))
    (should (looking-back "some text"))))

(ert-deftest ein:notebook-change-cell-type-cycle-through ()
  (with-current-buffer (eintest:notebook-make-empty)
    (call-interactively #'ein:worksheet-insert-cell-above)
    (insert "some text")
    ;; start with code cell
    (should (ein:codecell-p (ein:worksheet-get-current-cell)))
    (should (slot-boundp (ein:worksheet-get-current-cell) :kernel))
    (let ((check
           (lambda (type &optional level)
             (let ((cell-p (intern (format "ein:%scell-p" type)))
                   (cell (ein:worksheet-get-current-cell)))
               (ein:worksheet-change-cell-type ein:%worksheet% cell
                                               type level t)
               (let ((new (ein:worksheet-get-current-cell)))
                 (should-not (eq new cell))
                 (should (funcall cell-p new)))
               (should (looking-back "some text"))))))
      ;; change type: code (no change) -> markdown -> raw
      (loop for type in '("code" "markdown" "raw")
            do (funcall check type))
      ;; change level: 1 to 6
      (loop for level from 1 to 6
            do (funcall check "heading" level))
      ;; back to code
      (funcall check "code")
      (should (slot-boundp (ein:worksheet-get-current-cell) :kernel)))))

(defun eintest:notebook-split-cell-at-point
  (insert-text search-text head-text tail-text &optional no-trim)
  "Test `ein:notebook-split-cell-at-point' by the following procedure.

1. Insert, INSERT-TEXT.
2. Split cell just before SEARCH-TEXT.
3. Check that head cell has HEAD-TEXT.
4. Check that tail cell has TAIL-TEXT.

NO-TRIM is passed to `ein:notebook-split-cell-at-point'."
  (with-current-buffer (eintest:notebook-make-empty)
    (call-interactively #'ein:worksheet-insert-cell-above)
    (insert insert-text)
    (when search-text
      (search-backward search-text))
    ;; do it
    (let ((current-prefix-arg no-trim))
      (call-interactively #'ein:worksheet-split-cell-at-point))
    ;; check the "tail" cell
    (let ((cell (ein:worksheet-get-current-cell)))
      (ein:cell-goto cell)
      (should (equal (ein:cell-get-text cell) tail-text))
      (should (ein:codecell-p cell))
      (should (slot-boundp cell :kernel)))
    ;; check the "head" cell
    (call-interactively #'ein:worksheet-goto-prev-input)
    (let ((cell (ein:worksheet-get-current-cell)))
      (ein:cell-goto cell)
      (should (equal (ein:cell-get-text cell) head-text))
      (should (ein:codecell-p cell))
      (should (slot-boundp cell :kernel)))))

(ert-deftest ein:notebook-split-cell-at-point-before-newline ()
  (eintest:notebook-split-cell-at-point
   "some\ntext" "text" "some" "text"))

(ert-deftest ein:notebook-split-cell-at-point-after-newline ()
  (eintest:notebook-split-cell-at-point
   "some\ntext" "\ntext" "some" "text"))

(ert-deftest ein:notebook-split-cell-at-point-before-newline-no-trim ()
  (eintest:notebook-split-cell-at-point
   "some\ntext" "text" "some\n" "text" t))

(ert-deftest ein:notebook-split-cell-at-point-after-newline-no-trim ()
  (eintest:notebook-split-cell-at-point
   "some\ntext" "\ntext" "some" "\ntext" t))

(ert-deftest ein:notebook-split-cell-at-point-no-head ()
  (eintest:notebook-split-cell-at-point
   "some" "some" "" "some"))

(ert-deftest ein:notebook-split-cell-at-point-no-tail ()
  (eintest:notebook-split-cell-at-point
   "some" nil "some" ""))

(ert-deftest ein:notebook-merge-cell-command-next ()
  (with-current-buffer (eintest:notebook-make-empty)
    (call-interactively #'ein:worksheet-insert-cell-above)
    (insert "Cell 1")
    (call-interactively #'ein:worksheet-insert-cell-above)
    (insert "Cell 0")
    (let ((current-prefix-arg t))
      (call-interactively #'ein:worksheet-merge-cell))
    (ein:cell-goto (ein:worksheet-get-current-cell))
    (should (looking-at "Cell 0\nCell 1"))))

(ert-deftest ein:notebook-merge-cell-command-prev ()
  (with-current-buffer (eintest:notebook-make-empty)
    (call-interactively #'ein:worksheet-insert-cell-below)
    (insert "Cell 0")
    (call-interactively #'ein:worksheet-insert-cell-below)
    (insert "Cell 1")
    (call-interactively #'ein:worksheet-merge-cell)
    (ein:cell-goto (ein:worksheet-get-current-cell))
    (should (looking-at "Cell 0\nCell 1"))))

(ert-deftest ein:notebook-goto-next-input-command-simple ()
  (with-current-buffer (eintest:notebook-make-empty)
    (loop for i downfrom 2 to 0
          do (call-interactively #'ein:worksheet-insert-cell-above)
          do (insert (format "Cell %s" i)))
    (should (equal (ein:worksheet-ncells ein:%worksheet%) 3))
    ;; (message "%s" (buffer-string))
    (loop for i from 0 below 2
          do (beginning-of-line) ; This is required, I need to check why
          do (should (looking-at (format "Cell %s" i)))
          do (call-interactively #'ein:worksheet-goto-next-input)
          do (should (looking-at (format "Cell %s" (1+ i)))))))

(ert-deftest ein:notebook-goto-prev-input-command-simple ()
  (with-current-buffer (eintest:notebook-make-empty)
    (loop for i from 0 below 3
          do (call-interactively #'ein:worksheet-insert-cell-below)
          do (insert (format "Cell %s" i)))
    (should (equal (ein:worksheet-ncells ein:%worksheet%) 3))
    ;; (message "%s" (buffer-string))
    (loop for i downfrom 2 to 1
          do (beginning-of-line) ; This is required, I need to check why
          do (should (looking-at (format "Cell %s" i)))
          do (call-interactively #'ein:worksheet-goto-prev-input)
          do (should (looking-at (format "Cell %s" (1- i)))))))

(ert-deftest ein:notebook-move-cell-up-command-simple ()
  (with-current-buffer (eintest:notebook-make-empty)
    (loop for i from 0 below 3
          do (call-interactively #'ein:worksheet-insert-cell-below)
          do (insert (format "Cell %s" i)))
    (beginning-of-line)
    (should (looking-at "Cell 2"))
    (loop repeat 2
          do (call-interactively #'ein:worksheet-move-cell-up))
    ;; (message "%s" (buffer-string))
    (beginning-of-line)
    (should (looking-at "Cell 2"))
    (should (search-forward "Cell 0" nil t))
    (should (search-forward "Cell 1" nil t))
    (should-not (search-forward "Cell 2" nil t))))

(ert-deftest ein:notebook-move-cell-down-command-simple ()
  (with-current-buffer (eintest:notebook-make-empty)
    (loop for i from 0 below 3
          do (call-interactively #'ein:worksheet-insert-cell-above)
          do (insert (format "Cell %s" i)))
    (loop repeat 2
          do (call-interactively #'ein:worksheet-move-cell-down))
    (beginning-of-line)
    (should (looking-at "Cell 2"))
    (should (search-backward "Cell 0" nil t))
    (should (search-backward "Cell 1" nil t))
    (should-not (search-backward "Cell 2" nil t))))


;; Kernel related things

(defun eintest:notebook-check-kernel-and-codecell (kernel cell)
  (should (ein:$kernel-p kernel))
  (should (ein:codecell-p cell))
  (should (ein:$kernel-p (oref cell :kernel))))

(defun eintest:notebook-fake-execution (kernel text msg-id callbacks)
  (mocker-let ((ein:kernel-execute
                (kernel code callbacks kwd-silent silent)
                ((:input (list kernel text callbacks :silent nil))))
               (ein:kernel-live-p
                (kernel)
                ((:input (list kernel) :output t))))
    (call-interactively #'ein:worksheet-execute-cell))
  (ein:kernel-set-callbacks-for-msg kernel msg-id callbacks))

(ert-deftest ein:notebook-execute-current-cell ()
  (with-current-buffer (eintest:notebook-make-empty)
    (call-interactively #'ein:worksheet-insert-cell-below)
    (let* ((text "print 'Hello World'")
           (cell (ein:worksheet-get-current-cell))
           (kernel (ein:$notebook-kernel ein:%notebook%))
           (msg-id "DUMMY-MSG-ID")
           (callbacks (ein:cell-make-callbacks cell)))
      (eintest:notebook-check-kernel-and-codecell kernel cell)
      ;; Execute
      (insert text)
      (eintest:notebook-fake-execution kernel text msg-id callbacks)
      ;; Execute reply
      (should-error (eintest:check-search-forward-from (point-min) "In [1]:"))
      (eintest:kernel-fake-execute-reply kernel msg-id 1)
      (should (= (oref cell :input-prompt-number) 1))
      (eintest:check-search-forward-from (point-min) "In [1]:")
      ;; Stream output
      (eintest:kernel-fake-stream kernel msg-id "Hello World")
      (should (= (ein:cell-num-outputs cell) 1))
      (save-excursion
        (goto-char (point-min))
        (should (search-forward "In [1]:" nil t))
        (should (search-forward "print 'Hello World'" nil t))
        (should (search-forward "\nHello World\n" nil t)) ; stream output
        (should-not (search-forward "Hello World" nil t))))))

(defmacro eintest:worksheet-execute-cell-and-*-deftest
  (do-this cell-type has-next-p insert-p)
  "Define:
ein:worksheet-execute-cell-and-{DO-THIS}/on-{CELL-TYPE}cell-{no,with}-next

For example, when `goto-next', \"code\", `nil', `nil' is given,
`ein:worksheet-execute-cell-and-goto-next/on-codecell-no-next' is
defined."
  (let ((test-name
         (intern (format "ein:worksheet-execute-cell-and-%s/on-%scell-%s"
                         do-this cell-type
                         (if has-next-p "with-next" "no-next"))))
        (command
         (intern (format "ein:worksheet-execute-cell-and-%s" do-this))))
    `(ert-deftest ,test-name ()
       (with-current-buffer (eintest:notebook-make-empty)
         (let* ((ws ein:%worksheet%)
                (current (ein:worksheet-insert-cell-below ws ,cell-type nil t))
                ,@(when has-next-p
                    '((next
                       (ein:worksheet-insert-cell-below ws "code" current)))))
           (mocker-let ((ein:worksheet-execute-cell
                         (ws cell)
                         (,@(when (equal cell-type "code")
                              '((:input (list ein:%worksheet% current)))))))
             (call-interactively #',command)
             (let ((cell (ein:worksheet-get-current-cell)))
               (should (eq (ein:cell-prev cell) current))
               ,(when has-next-p
                  (if insert-p
                      '(should-not (eq cell next))
                    '(should (eq cell next)))))))))))

(eintest:worksheet-execute-cell-and-*-deftest goto-next    "code"     nil t  )
(eintest:worksheet-execute-cell-and-*-deftest goto-next    "code"     t   nil)
(eintest:worksheet-execute-cell-and-*-deftest goto-next    "markdown" nil t  )
(eintest:worksheet-execute-cell-and-*-deftest goto-next    "markdown" t   nil)
(eintest:worksheet-execute-cell-and-*-deftest insert-below "code"     nil t  )
(eintest:worksheet-execute-cell-and-*-deftest insert-below "code"     t   t  )
(eintest:worksheet-execute-cell-and-*-deftest insert-below "markdown" nil t  )
(eintest:worksheet-execute-cell-and-*-deftest insert-below "markdown" t   t  )


;; Notebook undo

(defun eintest:notebook-undo-after-insert-above ()
  (with-current-buffer (eintest:notebook-make-empty)
    (let ((text "some text"))
      (call-interactively #'ein:worksheet-insert-cell-above)
      (insert text)
      (undo-boundary)
      (call-interactively #'ein:worksheet-insert-cell-above)
      (call-interactively #'ein:worksheet-goto-next-input)
      (should (equal (ein:cell-get-text (ein:worksheet-get-current-cell)) text))
      (if (eq ein:notebook-enable-undo 'full)
          (undo)
        (should-error (undo)))
      (when (eq ein:notebook-enable-undo 'full)
        ;; FIXME: Known bug. (this must succeed.)
        (should-error (should (equal (buffer-string) "
In [ ]:


In [ ]:


")))))))

(defun eintest:notebook-undo-after-split ()
  (with-current-buffer (eintest:notebook-make-empty)
    (let ((line-1 "first line")
          (line-2 "second line"))
      (call-interactively #'ein:worksheet-insert-cell-below)
      (insert line-1 "\n" line-2)
      (undo-boundary)
      (move-beginning-of-line 1)
      (call-interactively #'ein:worksheet-split-cell-at-point)
      (undo-boundary)
      (should (equal (ein:cell-get-text (ein:worksheet-get-current-cell))
                     line-2))
      (if (eq ein:notebook-enable-undo 'full)
          (undo)
        (should-error (undo)))
      (when (eq ein:notebook-enable-undo 'full)
        (should (equal (buffer-string) "
In [ ]:


In [ ]:
first line
second line

"))))))

(defun eintest:notebook-undo-after-merge ()
  (with-current-buffer (eintest:notebook-make-empty)
    (let ((line-1 "first line")
          (line-2 "second line"))
      (call-interactively #'ein:worksheet-insert-cell-below)
      (call-interactively #'ein:worksheet-insert-cell-below)
      ;; Extra cells to avoid "Changes to be undone are outside visible
      ;; portion of buffer" user-error:
      (call-interactively #'ein:worksheet-insert-cell-below)
      (call-interactively #'ein:worksheet-insert-cell-below)
      (goto-char (point-min))
      (call-interactively #'ein:worksheet-goto-next-input)

      (insert line-1)
      (undo-boundary)

      (call-interactively #'ein:worksheet-goto-next-input)
      (insert line-2)
      (undo-boundary)

      (call-interactively #'ein:worksheet-merge-cell)
      (undo-boundary)

      (should (equal (ein:cell-get-text (ein:worksheet-get-current-cell))
                     (concat line-1 "\n" line-2)))
      (if (not (eq ein:notebook-enable-undo 'full))
          (should-error (undo))
        (undo)
        (should (equal (buffer-string) "
In [ ]:
second line

In [ ]:


In [ ]:


")))
      (when (eq ein:notebook-enable-undo 'yes)
        ;; FIXME: `undo' should work...
        (should-error (undo-more 1)))
      (when (eq ein:notebook-enable-undo 'full)
        (undo)
        ;; FIXME: Known bug... What should the result be?
        (should-error (should (equal (buffer-string) "
In [ ]:


In [ ]:


In [ ]:


")))))))

(defun eintest:notebook-undo-after-execution-1-cell ()
  (with-current-buffer (eintest:notebook-make-empty)
    (call-interactively #'ein:worksheet-insert-cell-below)
    (let* ((text "print 'Hello World'")
           (output-text "Hello World\n")
           (cell (ein:worksheet-get-current-cell))
           (kernel (ein:$notebook-kernel ein:%notebook%))
           (msg-id "DUMMY-MSG-ID")
           (callbacks (ein:cell-make-callbacks cell))
           (check-output
            (lambda ()
              (eintest:cell-check-output cell output-text))))
      (eintest:notebook-check-kernel-and-codecell kernel cell)
      ;; Execute
      (insert text)
      (undo-boundary)
      (eintest:notebook-fake-execution kernel text msg-id callbacks)
      (ein:kernel-set-callbacks-for-msg kernel msg-id callbacks)
      ;; Stream output
      (eintest:kernel-fake-stream kernel msg-id output-text)
      (funcall check-output)
      ;; Undo
      (should (equal (ein:cell-get-text cell) text))
      (if (eq ein:notebook-enable-undo 'full)
          (undo)
        (should-error (undo)))
      (when (eq ein:notebook-enable-undo 'full)
        (should (equal (ein:cell-get-text cell) ""))
        ;; FIXME: Known bug. (it must succeed.)
        (should-error (funcall check-output))))))

(defun eintest:notebook-undo-after-execution-2-cells ()
  (with-current-buffer (eintest:notebook-make-empty)
    (call-interactively #'ein:worksheet-insert-cell-below)
    (call-interactively #'ein:worksheet-insert-cell-above)
    (let* ((text "print 'Hello World\\n' * 10")
           (next-text "something")
           (output-text
            (apply #'concat (loop repeat 10 collect "Hello World\n")))
           (cell (ein:worksheet-get-current-cell))
           (next-cell (ein:cell-next cell))
           (kernel (ein:$notebook-kernel ein:%notebook%))
           (msg-id "DUMMY-MSG-ID")
           (callbacks (ein:cell-make-callbacks cell))
           (check-output
            (lambda ()
              (eintest:cell-check-output cell output-text))))
      (eintest:notebook-check-kernel-and-codecell kernel cell)
      ;; Execute
      (insert text)
      (undo-boundary)
      (let ((pos (point)))
        ;; Do not use `save-excursion' because it does not record undo.
        (call-interactively #'ein:worksheet-goto-next-input)
        (insert next-text)
        (undo-boundary)
        (goto-char pos))
      (eintest:notebook-fake-execution kernel text msg-id callbacks)
      (ein:kernel-set-callbacks-for-msg kernel msg-id callbacks)
      ;; Stream output
      (eintest:kernel-fake-stream kernel msg-id output-text)
      (funcall check-output)
      ;; Undo
      (should (equal (ein:cell-get-text cell) text))
      (should (equal (ein:cell-get-text next-cell) next-text))
      (if (eq ein:notebook-enable-undo 'full)
          (undo)
        (should-error (undo)))
      (when (eq ein:notebook-enable-undo 'full)
        (should (equal (ein:cell-get-text cell) text))
        ;; FIXME: Known bug. (these two must succeed.)
        (should-error (should (equal (ein:cell-get-text next-cell) "")))
        (should-error (funcall check-output))))))

(defmacro eintest:notebook-undo-make-tests (name)
  "Define three tests ein:NANE/no, ein:NANE/yes and ein:NANE/full
from a function named eintest:NAME where `no'/`yes'/`full' is the
value of `ein:notebook-enable-undo'."
  (let ((func (intern (format "eintest:%s" name)))
        (test/no (intern (format "ein:%s/no" name)))
        (test/yes (intern (format "ein:%s/yes" name)))
        (test/full (intern (format "ein:%s/full" name))))
    `(progn
       (ert-deftest ,test/no ()
         (let ((ein:notebook-enable-undo 'no))
           (,func)))
       (ert-deftest ,test/yes ()
         (let ((ein:notebook-enable-undo 'yes))
           (,func)))
       (ert-deftest ,test/full ()
         (let ((ein:notebook-enable-undo 'full))
           (,func))))))

(eintest:notebook-undo-make-tests notebook-undo-after-insert-above)
(eintest:notebook-undo-make-tests notebook-undo-after-split)
(eintest:notebook-undo-make-tests notebook-undo-after-merge)
(eintest:notebook-undo-make-tests notebook-undo-after-execution-1-cell)
(eintest:notebook-undo-make-tests notebook-undo-after-execution-2-cells)

(ert-deftest ein:notebook-undo-via-events ()
  (with-current-buffer (eintest:notebook-make-empty)
    (call-interactively #'ein:worksheet-insert-cell-below)
    (loop with events = (ein:$notebook-events ein:%notebook%)
          for ein:notebook-enable-undo in '(no yes full) do
          (let ((buffer-undo-list '(dummy))
                (cell (ein:worksheet-get-current-cell)))
            (with-temp-buffer
              (should-not (equal buffer-undo-list '(dummy)))
              (ein:events-trigger events 'maybe_reset_undo.Notebook cell))
            (if (eq ein:notebook-enable-undo 'yes)
                (should (equal buffer-undo-list nil))
              (should (equal buffer-undo-list '(dummy))))))))


;; Generic getter

(ert-deftest ein:get-url-or-port--notebook ()
  (with-current-buffer (eintest:notebook-make-empty)
    (should (equal (ein:get-url-or-port) "DUMMY-URL"))))

(ert-deftest ein:get-notebook--notebook ()
  (with-current-buffer (eintest:notebook-make-empty)
    (should (eq (ein:get-notebook) ein:%notebook%))))

(ert-deftest ein:get-kernel--notebook ()
  (with-current-buffer (eintest:notebook-make-empty)
    (let ((kernel (ein:$notebook-kernel ein:%notebook%)))
      (should (ein:$kernel-p kernel))
      (should (eq (ein:get-kernel) kernel)))))

(ert-deftest ein:get-cell-at-point--notebook ()
  (with-current-buffer (eintest:notebook-make-empty)
    ;; FIXME: write test with non-empty worksheet
    (should-not (ein:get-cell-at-point))))

(ert-deftest ein:get-traceback-data--notebook ()
  (with-current-buffer (eintest:notebook-make-empty)
    ;; FIXME: write test with non-empty TB
    (should-not (ein:get-traceback-data))))


;; Notebook mode

(ert-deftest ein:notebook-ask-before-kill-emacs-simple ()
  (let ((ein:notebook--opened-map (make-hash-table :test 'equal)))
    (should (ein:notebook-ask-before-kill-emacs))
    (with-current-buffer
        (eintest:notebook-enable-mode
         (eintest:notebook-make-empty "Modified Notebook" "NOTEBOOK-ID-1"))
      (call-interactively #'ein:worksheet-insert-cell-below)
      (should (ein:notebook-modified-p)))
    (with-current-buffer
        (eintest:notebook-enable-mode
         (eintest:notebook-make-empty "Unmodified Notebook" "NOTEBOOK-ID-2"))
      (should-not (ein:notebook-modified-p)))
    (flet ((y-or-n-p (&rest ignore) t)
           (ein:notebook-del (&rest ignore)))
      (kill-buffer
       (eintest:notebook-enable-mode
        (eintest:notebook-make-empty "Killed Notebook" "NOTEBOOK-ID-3"))))
    (should (= (hash-table-count ein:notebook--opened-map) 3))
    (mocker-let ((y-or-n-p
                  (prompt)
                  ((:input '("You have 1 unsaved notebook(s). Discard changes?")
                           :output t))))
      (should (ein:notebook-ask-before-kill-emacs)))))


;; Misc unit tests

(ert-deftest ein:notebook-test-notebook-name-simple ()
  (should-not (ein:notebook-test-notebook-name nil))
  (should-not (ein:notebook-test-notebook-name ""))
  (should-not (ein:notebook-test-notebook-name "/"))
  (should-not (ein:notebook-test-notebook-name "\\"))
  (should-not (ein:notebook-test-notebook-name "a/b"))
  (should-not (ein:notebook-test-notebook-name "a\\b"))
  (should (ein:notebook-test-notebook-name "This is a OK notebook name")))

(defun* eintest:notebook--check-nbformat (&optional orig_nbformat
                                                    orig_nbformat_minor
                                                    nbformat
                                                    nbformat_minor
                                                    &key data)
  (let ((data (or data
                  (list :nbformat nbformat :nbformat_minor nbformat_minor
                        :orig_nbformat orig_nbformat
                        :orig_nbformat_minor orig_nbformat_minor))))
    (ein:notebook--check-nbformat data)))

(ert-deftest ein:notebook--check-nbformat-nothing ()
  (mocker-let ((ein:display-warning (message) ()))
    (eintest:notebook--check-nbformat)
    (eintest:notebook--check-nbformat :data nil)
    (eintest:notebook--check-nbformat 2 0)
    (eintest:notebook--check-nbformat 2 0 2)
    (eintest:notebook--check-nbformat 2 0 2 0)))

(defmacro ein:notebook--check-nbformat-assert-match (regexp &rest args)
  `(mocker-let ((ein:display-warning
                 (message)
                 ((:input-matcher
                   (lambda (m) (string-match ,regexp m))))))
     (eintest:notebook--check-nbformat ,@args)))

(ert-deftest ein:notebook--check-nbformat-warn-major ()
  (ein:notebook--check-nbformat-assert-match "v2 -> v3" 2 nil 3)
  (ein:notebook--check-nbformat-assert-match "v2 -> v3" 2 0 3 0))

(ert-deftest ein:notebook--check-nbformat-warn-minor ()
  (ein:notebook--check-nbformat-assert-match
   "version v2\\.1, [^\\.]* up to v2.0" 2 1 2 0))

(provide 'test-ein-notebook)
