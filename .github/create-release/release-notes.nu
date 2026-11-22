# Prints the release notes for a `<crate>/v<version>` tag: the crate's
# CHANGELOG.md section for the version, that is the lines under its
# `## [<version>]` heading (release-plz's), up to the next `##` heading.
# Headings are found through nushell's Markdown parser (`from md
# --verbose`), so a `## ` inside a code block is not one; the section's own
# text is printed as written. Prints nothing when there is no such section.

# The plain text of a Markdown AST node (its text descendants, joined).
def text-of [node: record]: nothing -> string {
    if $node.type == "text" {
        $node.attrs.value
    } else {
        $node.children | each {|child| text-of $child } | str join
    }
}

# The version a `##` heading names: its text up to the first "]" or space,
# without a leading "[" ("0.1.1" for `## [0.1.1](...) - 2026-11-21`).
def heading-version [title: string]: nothing -> string {
    $title | str trim | str replace -r '^\[' '' | split row -r '[\] ]' | first
}

# The CHANGELOG.md beside the Cargo.toml of `crate` (under the current
# directory), or null.
def changelog-of [crate: string]: nothing -> any {
    let manifest = (
        glob **/Cargo.toml --exclude [**/target/** **/node_modules/**]
        | where {|m| (open $m | get -o package.name) == $crate }
        | get -o 0
    )
    if $manifest == null { return null }
    let changelog = $manifest | path dirname | path join CHANGELOG.md
    if ($changelog | path exists) { $changelog } else { null }
}

def main [tag: string] {
    let crate = $tag | str replace -r '/v[^/]*$' ''
    let version = $tag | str replace -r '^.*/v' ''
    let changelog = changelog-of $crate
    if $changelog == null { return }
    let raw = open --raw $changelog
    let lines = $raw | lines
    let headings = (
        $raw | from md --verbose
        | where type == "h2"
        | each {|h| {line: $h.position.start.line, version: (heading-version (text-of $h))} }
    )
    let found = $headings | enumerate | where {|e| $e.item.version == $version }
    if ($found | is-empty) { return }
    let index = $found | first | get index
    let start = ($headings | get $index | get line)
    let next = $headings | get -o ($index + 1)
    let end = if $next == null { $lines | length } else { $next.line - 1 }
    # Lines are 1-based; the section is the lines after the heading.
    $lines | slice $start..<$end | str join "\n" | str trim | print
}
