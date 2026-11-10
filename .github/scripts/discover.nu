const BOT = "xenondevs-deps-updater[bot]"
const MESSAGE = "chore(deps): regenerate gradle verification metadata"
const INPUTS = '(^|/)[^/]+\.gradle\.kts$|^gradle/libs\.versions\.toml$|^gradle/wrapper/gradle-wrapper\.properties$|^gradle\.properties$'

# Prints the renovate branches whose gradle inputs changed and that have not been regenerated yet as a job matrix.
def main [config: path] {
    let matrix = open $config | each {|entry|
        let base = gh api $"repos/($entry.repo)" | from json | get default_branch
        let branches = gh api --paginate $"repos/($entry.repo)/branches" --jq '.[].name' | lines | where {|it| $it starts-with "renovate/" }

        $branches | each {|branch|
            let compare = gh api $"repos/($entry.repo)/compare/($base)...($branch)" | from json
            let commits = $compare.commits

            let skip = if ($commits | is-empty) {
                "nothing ahead of the base branch"
            } else if ($commits | any {|commit| $commit.author?.login? != $BOT }) {
                "has commits that are not from the bot"
            } else if (($commits | last).commit.message | str starts-with $MESSAGE) {
                "already regenerated"
            } else if not ($compare.files | any {|file| $file.filename =~ $INPUTS }) {
                "no gradle inputs changed"
            }
            
            if $skip != null {
                print --stderr $"skip ($entry.repo) ($branch): ($skip)"
            } else {
                let sha = ($commits | last).sha
                print --stderr $"regenerate ($entry.repo) ($branch) at ($sha)"
                $entry | merge {name: ($entry.repo | split row "/" | last), branch: $branch, sha: $sha}
            }
        }
    } | flatten

    $"branches=($matrix | to json --raw)"
}
