#!/bin/bash
# entrypoint.sh

# Exit immediately if a command exits with a non-zero status.
set -e

# 1. TOKEN VALIDATION: Read the token from an environment variable.
if [ -z "$LFX_TOKEN" ]; then
    echo "Error: The LFX_TOKEN environment variable is not set." >&2
    exit 1
fi

# API and HTML settings
BASE_API_URL="https://api-gw.platform.linuxfoundation.org/project-service/v1/projects"
# Ensure the output file is created at the root of the repository checkout.
OUTPUT_HTML_FILE="${GITHUB_WORKSPACE}/index.html"
PAGE_SIZE=100
OFFSET=0

# Initialize accumulators for JSON data and counters.
# These variables will now be correctly updated in the main shell context.
PROJECTS_LISTED_COUNT=0 # This counts "Active" projects
FORMING_PROJECTS_JSON_LINES="" # Accumulates line-delimited JSON for forming projects
TOTAL_FORMING_PROJECTS_IDENTIFIED=0 # Counter for forming projects
MAIN_ACTIVE_PROJECTS_JSON_LINES="" # Accumulator for main active projects

echo "Fetching projects, filtering, sorting, and generating HTML..."
echo "--------------------------------------------------------------------------"

# Define jq functions (these remain unchanged, as they were already correct)
JQ_HTML_PROCESSOR='
def category_rank:
  if .Category == "TAG" then 1
  elif .Category == "Graduated" then 2
  elif .Category == "Incubating" then 3
  elif .Category == "Sandbox" then 4
  else 0
  end;

[inputs] |
map(. + {category_sort_key: category_rank}) |
map(select(.category_sort_key > 0)) |
sort_by([.category_sort_key, .Name]) |
group_by(.Category) |
sort_by(.[0].category_sort_key) |
map(
    (.[0].Category) as $current_category_name |
    (length) as $project_count |
    "<h2>" + $current_category_name + " (" + ($project_count | tostring) + ")</h2>\n<ul class=\"project-list\">\n" +
    (map(
        "<li class=\"project-item\"><img src=\"" + ((.ProjectLogo | select(length > 0)) // "https://lf-master-project-logos-prod.s3.us-east-2.amazonaws.com/cncf.svg") + "\" alt=\"" + .Name + " Logo\" class=\"project-logo\"> " + .Name + " (<a href=\"https://zoom-lfx.platform.linuxfoundation.org/meetings/" + (.Slug | @uri) + "\">Project calendar</a>)" +
        (if .RepositoryURL and (.RepositoryURL | length > 0) then " (<a href=\"" + .RepositoryURL + "\">Project code</a>)" else "" end) +
        "</li>\n"
    ) | add) +
    "</ul>\n"
) | add
'

JQ_FORMING_PROJECTS_PROCESSOR='
. | # Expects an array as input
sort_by(.Name) |
# Now map the array to HTML, including the count (length of the array)
(length) as $project_count |
"<h2>Forming Projects (" + ($project_count | tostring) + ")</h2>\n<ul class=\"project-list\">\n" +
(map(
    "<li class=\"project-item\"><img src=\"" + ((.ProjectLogo | select(length > 0)) // "https://lf-master-project-logos-prod.s3.us-east-2.amazonaws.com/cncf.svg") + "\" alt=\"" + .Name + " Logo\" class=\"project-logo\"> " + .Name +
    (if .RepositoryURL and (.RepositoryURL | length > 0) then " (<a href=\"" + .RepositoryURL + "\">GitHub</a>)" else "" end) +
    "</li>\n"
) | add) +
"</ul>\n"
'

# --- Data Collection Phase: This loop now POPULATES variables in the main shell ---
# The critical change is that there is NO PIPE after 'done' in this loop.
while true; do
    CURRENT_API_URL="${BASE_API_URL}?offset=${OFFSET}&limit=${PAGE_SIZE}"
    # Removed verbose DEBUG from here to focus on the final state.

    RESPONSE=$(curl -sS -H "Authorization: Bearer $LFX_TOKEN" "$CURRENT_API_URL")

    if [ -z "$RESPONSE" ]; then
        echo "Error: Empty response from API for offset $OFFSET. Check network or token." >&2
        break
    fi
    if ! echo "$RESPONSE" | jq -e '.Data' > /dev/null 2>&1; then
        echo "Error: Invalid JSON response or 'Data' array not found for offset $OFFSET. Stopping." >&2
        break
    fi

    PROJECTS_RECEIVED_ON_PAGE=$(echo "$RESPONSE" | jq '.Data | length')

    if [ "$PROJECTS_RECEIVED_ON_PAGE" -eq 0 ]; then
        break
    fi

    # Filter and accumulate projects for main categories (Status == "Active")
    FILTERED_JSON_STREAM_MAIN_CURRENT_PAGE=$(echo "$RESPONSE" | \
      jq -c --arg fid "a0941000002wBz4AAE" \
      '.Data[] | select(.Foundation.ID == $fid and .Status == "Active") | {Name: .Name, Slug: .Slug, Category: .Category, ProjectLogo: .ProjectLogo, RepositoryURL: .RepositoryURL}')

    NUM_MAIN_ACTIVE=$(echo "$FILTERED_JSON_STREAM_MAIN_CURRENT_PAGE" | wc -l)

    if [ -n "$FILTERED_JSON_STREAM_MAIN_CURRENT_PAGE" ]; then
        MAIN_ACTIVE_PROJECTS_JSON_LINES+="$FILTERED_JSON_STREAM_MAIN_CURRENT_PAGE"$'\n'
        PROJECTS_LISTED_COUNT=$((PROJECTS_LISTED_COUNT + NUM_MAIN_ACTIVE))
    fi

    # Filter and accumulate projects for "Formation - Exploratory" status
    FILTERED_JSON_STREAM_FORMING_CURRENT_PAGE=$(echo "$RESPONSE" | \
      jq -c --arg fid "a0941000002wBz4AAE" --arg status "$FORMING_PROJECTS_STATUS" \
      '.Data[] | select(.Foundation.ID == $fid and .Status == $status) | {Name: .Name, ProjectLogo: .ProjectLogo, RepositoryURL: .RepositoryURL}')

    NUM_FORMING_ON_PAGE=$(echo "$FILTERED_JSON_STREAM_FORMING_CURRENT_PAGE" | wc -l)

    if [ -n "$FILTERED_JSON_STREAM_FORMING_CURRENT_PAGE" ]; then
        FORMING_PROJECTS_JSON_LINES+="$FILTERED_JSON_STREAM_FORMING_CURRENT_PAGE"$'\n'
        TOTAL_FORMING_PROJECTS_IDENTIFIED=$((TOTAL_FORMING_PROJECTS_IDENTIFIED + NUM_FORMING_ON_PAGE))
    fi

    OFFSET=$((OFFSET + PROJECTS_RECEIVED_ON_PAGE))
    sleep 0.2
done # <-- NO PIPE HERE!


# --- HTML Generation Phase: Now use the collected data to build the HTML ---
OUTPUT_HTML_FILE="${GITHUB_WORKSPACE}/index.html" # Ensure GITHUB_WORKSPACE is used here too
{
    cat <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>CNCF Projects</title>
    <meta charset="utf-8">
    <style>
    body { font-family: Arial, sans-serif; margin: 20px; line-height: 1.6; background-color: #f4f7f6; }
    h1 { color: #2c3e50; text-align: center; margin-bottom: 30px; font-size: 2.5em; padding-bottom: 10px; border-bottom: 3px solid #3498db;}
    h2 { color: #34495e; border-bottom: 1px solid #bdc3c7; padding-bottom: 8px; margin-top: 30px; font-size: 1.8em; }
    ul { list-style-type: none; padding: 0; margin-left: 20px; }
    li {
        margin-bottom: 5px;
        font-size: 1.1em;
        background-color: #ffffff;
        padding: 5px 10px;
        border-radius: 5px;
        box-shadow: 0 2px 4px rgba(0,0,0,0.05);
    }
    a { color: #3498db; text-decoration: none; }
    a:hover { text-decoration: underline; color: #2980b9; }
    #search-box {
        width: 50%;
        padding: 10px;
        margin-bottom: 20px;
        border: 1px solid #ccc;
        border-radius: 5px;
        box-sizing: border-box;
        font-size: 1.1em;
    }
    .project-logo {
        width: 60px;
        height: 60px;
        vertical-align: middle;
        margin-right: 5px;
        object-fit: contain;
    }
    .main-cncf-logo {
        width: 60px !important;
        height: 60px !important;
        vertical-align: middle;
        margin-right: 8px;
        object-fit: contain;
    }
</style>
</head>
<body>
    <h1> </h1>
    <h2>Main Calendar</h2>
    <ul>
        <li><img src="https://lf-master-project-logos-prod.s3.us-east-2.amazonaws.com/cncf.svg" alt="CNCF Logo" width="200" height="200" style="vertical-align: middle; margin-right: 16px; object-fit: contain;"> CNCF Main calendar (<a href="https://zoom-lfx.platform.linuxfoundation.org/meetings/cncf">Project calendar</a>)</li>
    </ul>

    <input type="text" id="search-box" onkeyup="filterProjects()" placeholder="Search for projects...">

    <script>
        function filterProjects() {
            let input = document.getElementById('search-box');
            let filter = input.value.toUpperCase();
            let projectLists = document.getElementsByClassName('project-list');

            for (let i = 0; i < projectLists.length; i++) {
                let ul = projectLists[i];
                let li = ul.getElementsByClassName('project-item');

                let categoryHasVisibleProjects = false;

                for (let j = 0; j < li.length; j++) {
                    let projectItem = li[j];
                    let textValue = projectItem.textContent || projectItem.innerText;
                    if (textValue.toUpperCase().indexOf(filter) > -1) {
                        projectItem.style.display = "flex"; // Changed from "" to "flex" as per your previous HTML
                        categoryHasVisibleProjects = true;
                    } else {
                        projectItem.style.display = "none";
                    }
                }

                let h2 = ul.previousElementSibling;
                if (h2 && h2.tagName === 'H2') {
                    h2.style.display = categoryHasVisibleProjects ? "" : "none";
                }
            }
        }
    </script>

EOF

    # Generate HTML for main categories from the accumulated data
    if [ -n "$MAIN_ACTIVE_PROJECTS_JSON_LINES" ]; then
        jq -n -r "$JQ_HTML_PROCESSOR" <<< "$MAIN_ACTIVE_PROJECTS_JSON_LINES"
    else
        echo ""
    fi

    # Handle the "Forming Projects" HTML after the main content
    # DEBUG: Crucial check: What is the final content of FORMING_PROJECTS_JSON_LINES?
    echo "DEBUG: Final FORMING_PROJECTS_JSON_LINES CONTENT (raw) for HTML generation:" >&2
    if [ -z "$FORMING_PROJECTS_JSON_LINES" ]; then
        echo "(EMPTY STRING)" >&2
    else
        printf '%s' "$FORMING_PROJECTS_JSON_LINES" >&2 # Use printf for exact string
    fi
    echo "--------------------------------------------------------" >&2

    if [ -n "$FORMING_PROJECTS_JSON_LINES" ]; then
        # jq -s '.' slurps all lines into one array.
        # Then pipe to the processor which expects an array.
        jq -s '.' <<< "$FORMING_PROJECTS_JSON_LINES" | jq -r "$JQ_FORMING_PROJECTS_PROCESSOR"
    else
        # If no forming projects, display the header with (0) count and an empty list
        echo "<h2>Forming Projects (0)</h2>\n<ul class=\"project-list\">\n</ul>"
    fi

    # Print the HTML footer
    cat <<EOF
</body>
</html>
EOF
} > "$OUTPUT_HTML_FILE"

echo "--------------------------------------------------------------------------"
echo "Finished fetching projects and generating HTML."
# Calculate final counts from accumulated lines for accuracy
FINAL_MAIN_PROJECTS_COUNT=$(echo "$MAIN_ACTIVE_PROJECTS_JSON_LINES" | jq -c '.' | wc -l)
FINAL_FORMING_PROJECTS_COUNT=$(echo "$FORMING_PROJECTS_JSON_LINES" | jq -c '.' | wc -l)

echo "Total projects matching Foundation ID filter (main categories): $FINAL_MAIN_PROJECTS_COUNT"
echo "Total 'Formation - Exploratory' projects identified: $FINAL_FORMING_PROJECTS_COUNT"
echo "HTML file generated: $OUTPUT_HTML_FILE"

# 4. SET ACTION OUTPUT: Make the path to the generated file available to other steps.
echo "html_file=${OUTPUT_HTML_FILE}" >> "$GITHUB_OUTPUT"
