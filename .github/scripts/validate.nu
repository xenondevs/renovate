const MESSAGE = "chore(deps): regenerate gradle verification metadata"
const VERIFICATION = "gradle/verification-metadata.xml"
const WRAPPER = "gradle/wrapper/gradle-wrapper.properties"
const DISTRIBUTION = '^https://services\.gradle\.org/distributions/gradle-[0-9A-Za-z.\-]+-(?:bin|all)\.zip$'
const SHA256 = '^[0-9a-f]{64}$'

def reject [msg: string] {
    error make {msg: $msg}
}

# All the pinned artifact with the checksums accepted for each
def pins []: record -> table<key: string, sums: list<string>> {
    $in.content | where tag == "components" | first | get content | each {|component|
        let coordinates = $"($component.attributes.group):($component.attributes.name):($component.attributes.version)"

        $component.content | each {|artifact|
            let sums = $artifact.content | each {|checksum|
                if $checksum.tag != "sha256" {
                    reject $"($artifact.attributes.name): only sha256 entries are expected, found ($checksum.tag)"
                }
                [$checksum.attributes.value] ++ ($checksum.content | where tag == "also-trust" | each {|also| $also.attributes.value })
            } | flatten | sort

            if ($sums | is-empty) or ($sums | any {|sum| $sum !~ $SHA256 }) {
                reject $"($artifact.attributes.name): malformed checksum"
            }
            {key: $"($coordinates):($artifact.attributes.name)", sums: $sums}
        }
    } | flatten
}

# Flattens an element into sorted descriptions of its nodes so reordering doesnt count as a change
def nodes [prefix: string = ""]: record -> list<string> {
    let node = $in
    if $node.tag == null {
        return [$"($prefix)=($node.content)"]
    }

    let path = $"($prefix)/($node.tag)"
    [$"($path) ($node.attributes | to nuon)"] ++ ($node.content | each {|child| $child | nodes $path } | flatten) | sort
}

# Rejects a regenerated file that loosens the rules or changes the checksum of something already pinned.
def check-verification [old: string, new: string]: nothing -> nothing {
    let old_root = $old | from xml
    let new_root = $new | from xml

    if $new_root.tag != "verification-metadata" {
        reject $"unexpected root element ($new_root.tag)"
    }
    if ($new_root.content.tag | sort) != [components configuration] {
        reject "unexpected top-level sections"
    }

    let configuration = {|root| $root.content | where tag == "configuration" | first | nodes }
    if (do $configuration $old_root) != (do $configuration $new_root) {
        reject "the <configuration> section changed, trust rules are only edited by hand"
    }

    let old_pins = $old_root | pins
    let new_pins = $new_root | pins
    if ($new_pins | is-empty) {
        reject "no pinned artifacts left"
    }

    let kept = $old_pins | join ($new_pins | rename key regenerated) key
    let changed = $kept | where {|pin| $pin.sums != $pin.regenerated }
    if ($changed | is-not-empty) {
        reject $"checksum changed for ($changed | length) already pinned artifacts, first: ($changed.key | first)"
    }

    let added = ($new_pins | length) - ($kept | length)
    let removed = ($old_pins | length) - ($kept | length)
    print $"verification metadata: ($added) added, ($removed) removed, ($kept | length) unchanged"
}

# The wrapper properties with distributionSha256Sum set to the checksum gradle publishes for the distribution.
def wrapper-with-checksum []: string -> string {
    let properties = $in
    let url = $properties | parse --regex '(?m)^distributionUrl=(?<url>.*)$' | get url
    if ($url | is-empty) or ($properties !~ '(?m)^distributionSha256Sum=') {
        return $properties
    }

    let url = $url | first | str trim | str replace '\:' ':'
    if $url !~ $DISTRIBUTION {
        reject $"unexpected distribution url ($url)"
    }
    let checksum = curl --fail --silent --show-error --location $"($url).sha256" | str trim
    if $checksum !~ $SHA256 {
        reject $"gradle returned a malformed checksum for ($url)"
    }
    $properties | str replace --regex '(?m)^distributionSha256Sum=.*$' $"distributionSha256Sum=($checksum)"
}

# Validate a regenerated verification-metadata.xml and write the commit gql
#
# The regenerated file comes from a job that ran the target repo's build, so it is untrusted input. The wrapper
# checksum is not taken from that job at all. Its fetched here and the job that holds the write token only sends
# what this writes.
def main [repo: string, branch: string, sha: string, regenerated: path, payload: path] {
    let fetch = {|path|
        let result = gh api -H "Accept: application/vnd.github.raw" $"repos/($repo)/contents/($path)?ref=($sha)" | complete # trailing newline
        if $result.exit_code != 0 {
            reject $"could not read ($path): ($result.stderr | str trim)"
        }
        $result.stdout
    }

    let old = do $fetch $VERIFICATION
    let new = open --raw $regenerated | decode utf-8
    check-verification $old $new

    let properties = do $fetch $WRAPPER
    let wrapper = $properties | wrapper-with-checksum
    if $wrapper != $properties {
        print "wrapper: distributionSha256Sum updated"
    }

    let additions = [[path contents]; [$VERIFICATION $new] [$WRAPPER $wrapper]]
        | zip [$old $properties]
        | where {|pair| $pair.0.contents != $pair.1 }
        | each {|pair| {path: $pair.0.path, contents: ($pair.0.contents | encode base64)} }

    if ($additions | is-empty) {
        print "nothing to commit"
        {} | to json | save --force $payload
        return
    }

    {
        query: "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }"
        variables: {
            input: {
                branch: {repositoryNameWithOwner: $repo, branchName: $branch}
                message: {headline: $MESSAGE}
                # refuses the commit if the branch moved since it was regenerated
                expectedHeadOid: $sha
                fileChanges: {additions: $additions}
            }
        }
    } | to json | save --force $payload
    print $"commit request written for ($additions.path | str join ', ')"
}
