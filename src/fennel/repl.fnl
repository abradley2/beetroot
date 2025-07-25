;; This module is the read/eval/print loop; for coding Fennel interactively.

;; The most complex thing it does is locals-saving, which allows locals to be
;; preserved in between "chunks"; by default Lua throws away all locals after
;; evaluating each piece of input.

(local {: copy &as utils} (require :fennel.utils))
(local parser (require :fennel.parser))
(local compiler (require :fennel.compiler))
(local specials (require :fennel.specials))
(local view (require :fennel.view))

(var depth 0)

(fn prompt-for [top?]
  (if top?
      (.. (string.rep ">" (+ depth 1)) " ")
      (.. (string.rep "." (+ depth 1)) " ")))

(fn default-read-chunk [parser-state]
  (io.write (prompt-for (= 0 parser-state.stack-size)))
  (io.flush)
  (case (io.read)
    input (.. input "\n")))

(fn default-on-values [xs]
  (io.write (table.concat xs "\t"))
  (io.write "\n"))

;; fnlfmt: skip
(fn default-on-error [errtype err]
  (io.write
   (case errtype
     "Runtime" (.. (compiler.traceback (tostring err) 4) "\n")
     _ (: "%s error: %s\n" :format errtype (tostring err)))))

(fn splice-save-locals [env lua-source scope]
  (let [saves (icollect [name (pairs env.___replLocals___)]
                (: "local %s = ___replLocals___[%q]"
                   :format (or (. scope.manglings name) name) name))
        binds (icollect [raw name (pairs scope.manglings)]
                (when (and (. scope.symmeta raw) (not (. scope.gensyms name)))
                  (: "___replLocals___[%q] = %s"
                     :format raw name)))
        gap (if (lua-source:find "\n") "\n" " ")]
    (.. (if (next saves) (.. (table.concat saves " ") gap) "")
        (case (lua-source:match "^(.*)[\n ](return .*)$")
          (body return) (.. body gap (table.concat binds " ") gap return)
          _ lua-source))))

(local commands {})

(fn completer [env scope text ?fulltext _from _to]
  (let [max-items 2000 ; to stop explosion on too mny items
        seen {}
        matches []
        input-fragment (text:gsub ".*[%s)(]+" "")]
    (var stop-looking? false)

    (fn add-partials [input tbl prefix] ; add partial key matches in tbl
      ;; When matching on global env or repl locals, iterate *manglings* to include nils
      (local scope-first? (or (= tbl env) (= tbl env.___replLocals___)))
      (icollect [k is-mangled (utils.allpairs (if scope-first? scope.manglings tbl))
                 :into matches :until (<= max-items (length matches))]
        (let [lookup-k (if scope-first? is-mangled k)]
          (when (and (= (type k) :string) (= input (k:sub 0 (length input)))
                     ;; manglings iterated for globals & locals, but should only match once
                     (not (. seen k))
                     ;; only match known  functions when we encounter a method call
                     (or (not= ":" (prefix:sub -1)) (= :function (type (. tbl lookup-k)))))
            (tset seen k true)
            (.. prefix k)))))

    (fn descend [input tbl prefix add-matches method?]
      (let [splitter (if method? "^([^:]+):(.*)" "^([^.]+)%.(.*)")
            (head tail) (input:match splitter)
            raw-head (or (. scope.manglings head) head)]
        (when (= (type (. tbl raw-head)) :table)
          (set stop-looking? true)
          (if method?
              (add-partials tail (. tbl raw-head) (.. prefix head ":"))
              (add-matches tail (. tbl raw-head) (.. prefix head))))))

    (fn add-matches [input tbl prefix]
      (let [prefix (if prefix (.. prefix ".") "")]
        (if (and (not (input:find "%.")) (input:find ":")) ; found a method call
            (descend input tbl prefix add-matches true)
            (not (input:find "%.")) ; done descending; add matches
            (add-partials input tbl prefix)
            (descend input tbl prefix add-matches false))))

    ;; When ?fulltext is available, check that for comma completion to avoid
    ;; completing commands in the middle of an expression
    (case (: (tostring (or ?fulltext text)) :match "^%s*,([^%s()[%]]*)$")
      cmd-fragment (add-partials cmd-fragment commands ",")
      _ (each [_ source (ipairs [scope.specials scope.macros
                                 (or env.___replLocals___ []) env env._G])
               :until stop-looking?]
          (add-matches input-fragment source)))
    matches))

(fn command? [input]
  (input:match "^%s*,"))

(fn command-docs []
  (table.concat (icollect [name f (utils.stablepairs commands)]
                  (: "  ,%s - %s" :format name
                     (or (compiler.metadata:get f :fnl/docstring) :undocumented)))
                "\n"))

;; fnlfmt: skip
(fn commands.help [_ _ on-values]
  "Show this message."
  (on-values [(.. "Welcome to Fennel.
This is the REPL where you can enter code to be evaluated.
You can also run these repl commands:

" (command-docs) "
  ,return FORM - Evaluate FORM and return its value to the REPL's caller.
  ,exit - Leave the repl.

Use ,doc something to see descriptions for individual macros and special forms.
Values from previous inputs are kept in *1, *2, and *3.

For more information about the language, see https://fennel-lang.org/reference")]))

;; Can't rely on metadata being enabled at load time for Fennel's own internals.
(compiler.metadata:set commands.help :fnl/docstring "Show this message.")

(fn reload [module-name env on-values on-error]
  ;; Sandbox the reload inside the limited environment, if present.
  (case (pcall (specials.load-code "return require(...)" env) module-name)
    (true old) (let [old-macro-module (. specials.macro-loaded module-name)
                     _ (tset specials.macro-loaded module-name nil)
                     _ (tset package.loaded module-name nil)
                     new (case (pcall require module-name)
                           (true new) new
                           (_ msg) (do ; keep the old module if reload failed
                                     (on-error :Repl msg)
                                     (tset specials.macro-loaded module-name old-macro-module)
                                     old))]
                 ;; if the module isn't a table then we can't make changes
                 ;; which affect already-loaded code, but if it is then we
                 ;; should splice new values into the existing table and
                 ;; remove values that are gone.
                 (when (and (= (type old) :table) (= (type new) :table))
                   (each [k v (pairs new)]
                     (tset old k v))
                   (each [k (pairs old)]
                     (when (= nil (. new k))
                       (tset old k nil)))
                   (tset package.loaded module-name old))
                 (on-values [:ok]))
    (false msg) (if (msg:match "loop or previous error loading module")
                    (do (tset package.loaded module-name nil)
                        (reload module-name env on-values on-error))
                    (. specials.macro-loaded module-name)
                    (tset specials.macro-loaded module-name nil)
                    ;; only show the error if it's not found in package.loaded
                    ;; AND macro-loaded
                    (on-error :Runtime (pick-values 1 (msg:gsub "\n.*" ""))))))

(fn run-command [read on-error f]
  (case (pcall read)
    (true true val) (case (pcall f val)
                      (false msg) (on-error :Runtime msg))
    false (on-error :Parse "Couldn't parse input.")))

(fn commands.reload [env read on-values on-error]
  (run-command read on-error #(reload (tostring $) env on-values on-error)))

(compiler.metadata:set commands.reload :fnl/docstring
                       "Reload the specified module.")

(fn commands.reset [env _ on-values]
  (set env.___replLocals___ {})
  (on-values [:ok]))

(compiler.metadata:set commands.reset :fnl/docstring
                       "Erase all repl-local scope.")

(fn commands.complete [env read on-values on-error scope chars]
  (run-command read on-error
               #(on-values (completer env scope (-> (table.concat chars)
                                                    (: :gsub "^%s*,complete%s+" "")
                                                    (: :sub 1 -2))))))

(compiler.metadata:set commands.complete :fnl/docstring
                       "Print all possible completions for a given input symbol.")

(fn apropos* [pattern tbl prefix seen names]
  ;; package.loaded can contain modules with dots in the names.  Such
  ;; names are renamed to contain / instead of a dot.
  (each [name subtbl (pairs tbl)]
    (when (and (= :string (type name))
               (not= package subtbl))
      (case (type subtbl)
        :function (when (: (.. prefix name) :match pattern)
                    (table.insert names (.. prefix name)))
        :table (when (not (. seen subtbl))
                 (apropos* pattern subtbl
                           (.. prefix (name:gsub "%." "/") ".")
                           (doto seen (tset subtbl true))
                           names)))))
  names)

(fn apropos [pattern]
  ;; _G. part is stripped from patterns to provide more stable output.
  ;; The order we traverse package.loaded is arbitrary, so we may see
  ;; top level functions either as is or under the _G module.
  (apropos* (pattern:gsub "^_G%." "") package.loaded "" {} []))

(fn commands.apropos [_env read on-values on-error _scope]
  (run-command read on-error #(on-values (apropos (tostring $)))))

(compiler.metadata:set commands.apropos :fnl/docstring
                       "Print all functions matching a pattern in all loaded modules.")

(fn apropos-follow-path [path]
  ;; Follow path to the target based on apropos path format
  (let [paths (icollect [p (path:gmatch "[^%.]+")] p)]
    (var tgt package.loaded)
    (each [_ path (ipairs paths)
           :until (= nil tgt)]
      (set tgt (. tgt (pick-values 1 (path:gsub "%/" ".")))))
    tgt))

(fn apropos-doc [pattern]
  "Search function documentations for a given pattern."
  (icollect [_ path (ipairs (apropos ".*"))]
    (let [tgt (apropos-follow-path path)]
      (when (= :function (type tgt))
        (case (compiler.metadata:get tgt :fnl/docstring)
          docstr (and (docstr:match pattern) path))))))

(fn commands.apropos-doc [_env read on-values on-error _scope]
  (run-command read on-error #(on-values (apropos-doc (tostring $)))))

(compiler.metadata:set commands.apropos-doc :fnl/docstring
                       "Print all functions that match the pattern in their docs")

(fn apropos-show-docs [on-values pattern]
  "Print function documentations for a given function pattern."
  (each [_ path (ipairs (apropos pattern))]
    (let [tgt (apropos-follow-path path)]
      (when (and (= :function (type tgt))
                 (compiler.metadata:get tgt :fnl/docstring))
        (on-values [(specials.doc tgt path)])
        (on-values [])))))

(fn commands.apropos-show-docs [_env read on-values on-error]
  (run-command read on-error #(apropos-show-docs on-values (tostring $))))

(compiler.metadata:set commands.apropos-show-docs :fnl/docstring
                       "Print all documentations matching a pattern in function name")

(fn resolve [identifier {: ___replLocals___ &as env} scope]
  (let [e (setmetatable {} {:__index #(or (. ___replLocals___
                                             (. scope.unmanglings $2))
                                          (. env $2))})]
    (case-try (pcall compiler.compile-string (tostring identifier) {: scope})
      (true code) (pcall (specials.load-code code e))
      (true val) val
      (catch _ nil))))

(fn commands.find [env read on-values on-error scope]
  (run-command read on-error
               #(case (-?> (utils.sym? $) (resolve env scope) (debug.getinfo))
                  (where {:what "Lua" : source :linedefined line}
                         (= :string (type source))
                         (= "@" (source:sub 1 1)))
                  (let [fnlsrc (?. compiler.sourcemap source line 2)]
                    (on-values [(string.format "%s:%s" (source:sub 2) (or fnlsrc line))]))
                  nil (on-error :Repl "Unknown value")
                  _ (on-error :Repl "No source info"))))

(compiler.metadata:set commands.find :fnl/docstring
                       "Print the filename and line number for a given function")

(fn commands.doc [env read on-values on-error scope]
  (run-command read on-error
               #(let [name (tostring $)
                      path (or (utils.multi-sym? name) [name])
                      (ok? target) (pcall #(or (. scope.specials name)
                                               (utils.get-in scope.macros path)
                                               (resolve name env scope)))]
                  (if ok?
                      (on-values [(specials.doc target name)])
                      (on-error :Repl (.. "Could not find " name " for docs."))))))

(compiler.metadata:set commands.doc :fnl/docstring
                       "Print the docstring and arglist for a function, macro, or special form.")

(fn commands.compile [_ read on-values on-error _ _ opts]
  (run-command read on-error
               #(case (pcall compiler.compile $ opts)
                  (true result) (on-values [result])
                  (_ msg) (on-error :Repl (.. "Error compiling expression: " msg)))))

(compiler.metadata:set commands.compile :fnl/docstring
                       "compiles the expression into lua and prints the result.")

;; note that this is sub-optimal for nested repls; the loaded commands should
;; be kept in a session-specific location rather than top-level commands table.
(fn load-plugin-commands [plugins]
  ;; first function to provide a command should win
  (for [i (length (or plugins [])) 1 -1]
    (each [name f (pairs (. plugins i))]
      (case (name:match "^repl%-command%-(.*)")
        cmd-name (tset commands cmd-name f)))))

(fn run-command-loop [input read loop env on-values on-error scope chars opts]
  (let [command-name (input:match ",([^%s/]+)")]
    (case (. commands command-name)
      command (command env read on-values on-error scope chars opts)
      _ (when (and (not= command-name :exit) (not= command-name :return))
          (on-values ["Unknown command" command-name])))
    (when (not= :exit command-name)
      (loop (= command-name :return)))))

(fn try-readline! [opts ok readline]
  (when ok
    (when readline.set_readline_name
      (readline.set_readline_name :fennel))
    ;; set the readline defaults now; fennelrc can override them later
    (readline.set_options {:keeplines 1000 :histfile ""})

    (fn opts.readChunk [parser-state]
      (case (readline.readline (prompt-for (= 0 parser-state.stack-size)))
        input (.. input "\n")))

    (var completer nil)

    (fn opts.registerCompleter [repl-completer]
      (set completer repl-completer))

    (fn repl-completer [text from to]
      (if completer
          (do (readline.set_completion_append_character "")
              (completer (text:sub from to) text from to))
          []))

    (readline.set_complete_function repl-completer)
    readline))

(fn should-use-readline? [opts]
  (and (not= "dumb" (os.getenv "TERM"))
       (not opts.readChunk)
       (not opts.registerCompleter)))

(fn repl [?options]
  (let [old-root-options utils.root.options
        {:fennelrc ?fennelrc &as opts} (copy ?options)
        _ (set opts.fennelrc nil)
        readline (and (should-use-readline? opts)
                      (try-readline! opts (pcall require :readline)))
        _ (when ?fennelrc (?fennelrc))
        env (specials.wrap-env (or opts.env (rawget _G :_ENV) _G))
        callbacks {:readChunk (or opts.readChunk default-read-chunk)
                   :onValues (or opts.onValues default-on-values)
                   :onError (or opts.onError default-on-error)
                   :pp (or opts.pp view)
                   :view-opts (or opts.view-opts {:depth 4})
                   :env env}
        save-locals? (not= opts.saveLocals false)
        (byte-stream clear-stream) (parser.granulate #(callbacks.readChunk $))
        chars []
        (read reset) (parser.parser (fn [parser-state]
                                      (let [b (byte-stream parser-state)]
                                        (when b
                                          (table.insert chars (string.char b)))
                                        b)))]
    (set depth (+ depth 1))
    (when opts.message
      (callbacks.onValues [opts.message]))
    (set env.___repl___ callbacks)
    (set (opts.env opts.scope) (values env (compiler.make-scope)))
    ;; use metadata unless we've specifically disabled it
    (set opts.useMetadata (not= opts.useMetadata false))
    (when (= opts.allowedGlobals nil)
      (set opts.allowedGlobals (specials.current-global-names env)))
    (when opts.init (opts.init opts depth))
    (when opts.registerCompleter
      (opts.registerCompleter (partial completer env opts.scope)))
    (load-plugin-commands opts.plugins)

    (when save-locals?
      (fn newindex [t k v] (when (. opts.scope.manglings k) (rawset t k v)))
      (set env.___replLocals___ (setmetatable {} {:__newindex newindex})))

    (fn print-values [...]
      (let [vals [...]
            out []
            pp callbacks.pp]
        (set (env._ env.__) (values (. vals 1) vals))
        ;; ipairs won't work here because of sparse tables
        (for [i 1 (select "#" ...)]
          (table.insert out (pp (. vals i) callbacks.view-opts)))
        (callbacks.onValues out)))

    (fn save-value [...]
      (set env.___replLocals___.*3 env.___replLocals___.*2)
      (set env.___replLocals___.*2 env.___replLocals___.*1)
      (set env.___replLocals___.*1 ...)
      ...)

    (set (opts.scope.manglings.*1 opts.scope.unmanglings._1) (values "_1" "*1"))
    (set (opts.scope.manglings.*2 opts.scope.unmanglings._2) (values "_2" "*2"))
    (set (opts.scope.manglings.*3 opts.scope.unmanglings._3) (values "_3" "*3"))

    (fn loop [exit-next?]
      (each [k (pairs chars)]
        (tset chars k nil))
      (reset)
      (let [(ok parser-not-eof? form) (pcall read)
            src-string (table.concat chars)
            ;; Work around a bug introduced in lua-readline 3.2
            readline-not-eof? (or (not readline) (not= src-string "(null)"))
            not-eof? (and readline-not-eof? parser-not-eof?)]
        (if (not ok)
            (do
              (callbacks.onError :Parse not-eof?)
              (clear-stream)
              (loop))
            (command? src-string)
            (run-command-loop src-string read loop env
                              callbacks.onValues callbacks.onError
                              opts.scope chars opts)
            (when not-eof?
              (case-try (pcall compiler.compile form
                               (doto opts (tset :source src-string)))
                (true src) (let [src (if save-locals?
                                         (splice-save-locals env src opts.scope)
                                         src)]
                             (pcall specials.load-code src env))
                (true chunk) (xpcall #(print-values (save-value (chunk)))
                                     (partial callbacks.onError :Runtime))
                (catch
                 (false msg) (do (clear-stream)
                                 (callbacks.onError :Compile msg))))
              (set utils.root.options old-root-options)
              (if exit-next?
                  env.___replLocals___.*1
                  (loop))))))

    (let [value (loop)]
      (set depth (- depth 1))
      (when readline
        (readline.save_history))
      (when opts.exit (opts.exit opts depth))
      value)))

(local repl-mt {:__index {: repl}})
(fn repl-mt.__call [{: view-opts &as overrides} ?opts]
  (let [opts (copy ?opts  (copy overrides))]
    (set opts.view-opts (copy (?. ?opts :view-opts) (copy view-opts)))
    (repl opts)))
;; Setting empty view-opts allows easy `(set ___repl___.view-opts.foo)`
;; without error or accidentally removing other options
(setmetatable {:view-opts {}} repl-mt)
