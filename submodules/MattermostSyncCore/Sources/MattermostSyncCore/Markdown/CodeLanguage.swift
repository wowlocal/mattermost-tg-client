import Foundation

extension MattermostMarkdown {
    /// The language of a fenced code block as the app's highlighter (libprisma, Prism grammars) names it.
    ///
    /// Mattermost's clients highlight with highlight.js, whose names and aliases differ from Prism's in places
    /// (`golang`, `c++`, `zsh`, `pgsql`, …). Prism's own aliases (`js`, `py`, `sh`, `yml`, `ts`, `rb`, `kt`, …) are
    /// in libprisma's grammar table already and pass through, lowercased. Nil for an empty info string.
    public static func codeLanguage(_ language: String?) -> String? {
        guard let language = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !language.isEmpty else {
            return nil
        }
        return codeLanguageAliases[language] ?? language
    }

    static let codeLanguageAliases: [String: String] = [
        "golang": "go",
        "c++": "cpp",
        "cxx": "cpp",
        "hpp": "cpp",
        "cc": "cpp",
        "h": "c",
        "c#": "csharp",
        "f#": "fsharp",
        "objective-c": "objectivec",
        "obj-c": "objc",
        "zsh": "bash",
        "terminal": "bash",
        "console": "shell-session",
        "ps1": "powershell",
        "pwsh": "powershell",
        "ps": "powershell",
        "bat": "batch",
        "cmd": "batch",
        "proto": "protobuf",
        "tf": "hcl",
        "terraform": "hcl",
        "erl": "erlang",
        "ex": "elixir",
        "exs": "elixir",
        "pl": "perl",
        "pm": "perl",
        "rs": "rust",
        "htm": "html",
        "xhtml": "html",
        "plist": "xml",
        "pgsql": "sql",
        "postgresql": "sql",
        "postgres": "sql",
        "mysql": "sql",
        "sqlite": "sql",
        "jsonc": "json",
        "gql": "graphql",
        "mk": "makefile",
        "make": "makefile",
        "patch": "diff",
        "clj": "clojure",
        "cljs": "clojure",
        "ml": "ocaml",
        "delphi": "pascal",
        "vue": "markup",
        "svelte": "markup",
        "mjs": "javascript",
        "cjs": "javascript",
        "node": "javascript",
    ]
}
