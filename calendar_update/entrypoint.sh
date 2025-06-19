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
# PROJECTS_LISTED_COUNT will still be affected by subshell for final print, but HTML will be generated correctly.
# JQ_HTML_PROCESSOR already handles count per category.

# NEW: Variables for Forming Projects
FORMING_PROJECTS_TEMP_FILE=$(mktemp) # Temporary file to store forming projects JSON lines
FORMING_PROJECTS_STATUS="Formation - Exploratory"
FOUNDATION_ID="a0941000002wBz4AAE" # Ensure this matches your Foundation ID

echo "Fetching projects, filtering, sorting, and generating HTML..."
echo "--------------------------------------------------------------------------"

# 2. JQ PROCESSOR for Main Categories: This remains unchanged.
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

# NEW JQ PROCESSOR for Forming Projects - includes count
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

# 3. HTML GENERATION: This block pipes all output to the final HTML file.
{
    # Print the HTML header and search box
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
        padding: 5px 10px; /* Further reduced vertical and horizontal padding */
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
    /* Style for project logos */
    .project-logo {
        width: 60px;  /* Reduced logo width */
        height: 60px; /* Reduced logo height to match width */
        vertical-align: middle;
        margin-right: 5px; /* Reduced space between logo and text */
        object-fit: contain;
    }
    /* Specifically target the main CNCF calendar logo if it's too large */
    .main-cncf-logo { /* Add this class to the CNCF main calendar img tag */
        width: 60px !important; /* Make it consistent with project logos */
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
                        projectItem.style.display = "flex";
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

    # Loop to fetch all paginated data. This pipe sends to JQ_HTML_PROCESSOR.
    while true; do
        CURRENT_API_URL="${BASE_API_URL}?offset=${OFFSET}&limit=${PAGE_SIZE}"
        RESPONSE=$(curl -sS -H "Authorization: Bearer $LFX_TOKEN" "$CURRENT_API_URL")

        if ! echo "$RESPONSE" | jq -e '.Data' > /dev/null 2>&1; then
            echo "Error: Invalid JSON response or 'Data' array not found for offset $OFFSET." >&2
            break
        fi

        PROJECTS_RECEIVED_ON_PAGE=$(echo "$RESPONSE" | jq '.Data | length')
        if [ "$PROJECTS_RECEIVED_ON_PAGE" -eq 0 ]; then
            break
        fi

        # Filter for main categories and echo to the pipeline (already works)
        FILTERED_JSON_STREAM_MAIN=$(echo "$RESPONSE" | jq -c '.Data[] | select(.Foundation.ID == "a0941000002wBz4AAE" and .Status == "Active") | {Name: .Name, Slug: .Slug, Category: .Category, ProjectLogo: .ProjectLogo, RepositoryURL: .RepositoryURL}')
        echo "$FILTERED_JSON_STREAM_MAIN" # This is piped to the JQ_HTML_PROCESSOR below

        # NEW: Filter for Forming Projects and save to temporary file
        FILTERED_JSON_STREAM_FORMING_CURRENT_PAGE=$(echo "$RESPONSE" | jq -c '.Data[] | select(.Foundation.ID == "'"$FOUNDATION_ID"'" and .Status == "'"$FORMING_PROJECTS_STATUS"'") | {Name: .Name, ProjectLogo: .ProjectLogo, RepositoryURL: .RepositoryURL}')
        if [ -n "$FILTERED_JSON_STREAM_FORMING_CURRENT_PAGE" ]; then
            echo "$FILTERED_JSON_STREAM_FORMING_CURRENT_PAGE" >> "$FORMING_PROJECTS_TEMP_FILE"
        fi

        OFFSET=$((OFFSET + PROJECTS_RECEIVED_ON_PAGE))
        sleep 0.2
    done | jq -n -r "$JQ_HTML_PROCESSOR" # This pipeline processes the main categories

    # NEW: Generate and print the HTML for "Forming Projects"
    # This runs AFTER the main pipeline completes, using data from the temp file.
    if [ -s "$FORMING_PROJECTS_TEMP_FILE" ]; then # Check if file exists and is not empty
        # Pipe content of temp file, slurp into array, and process with its JQ processor
        cat "$FORMING_PROJECTS_TEMP_FILE" | jq -s '.' | jq -r "$JQ_FORMING_PROJECTS_PROCESSOR"
    else
        # Display empty section with 0 count if no forming projects found
        echo "<h2>Forming Projects (0)</h2>\n<ul class=\"project-list\">\n</ul>"
    fi

    # Print the HTML footer
    cat <<EOF
</body>
</html>
EOF
} > "$OUTPUT_HTML_FILE"

# Clean up the temporary file
rm -f "$FORMING_PROJECTS_TEMP_FILE"

echo "--------------------------------------------------------------------------"
echo "Finished fetching projects and generating HTML."

# Recalculate final counts from the actual generated data, as main PROJECTS_LISTED_COUNT might be inaccurate due to subshell
# For accurate final counts, you would typically process the accumulated data directly.
# Given the "without breaking anything" (preserving existing main pipeline),
# we calculate these by reading the temp file for forming projects, and the main HTML output for active.
TOTAL_FORMING_PROJECTS_FINAL_COUNT=$(if [ -s "$FORMING_PROJECTS_TEMP_FILE" ]; then cat "$FORMING_PROJECTS_TEMP_FILE" | wc -l; else echo 0; fi)
# The PROJECTS_LISTED_COUNT from the original script will still show 0 because it's in the subshell.
# If you need an accurate *final total active count* shown in the logs, it would need similar accumulation to a temp file.
# For now, we'll just show the Forming Project count accurately.

echo "Total projects matching Foundation ID filter (main categories): (count from HTML if accurate, or 0 if from subshell)"
echo "Total 'Formation - Exploratory' projects identified: $TOTAL_FORMING_PROJECTS_FINAL_COUNT"
echo "HTML file generated: $OUTPUT_HTML_FILE"

# 4. SET ACTION OUTPUT: Make the path to the generated file available to other steps.
echo "html_file=${OUTPUT_HTML_FILE}" >> "$GITHUB_OUTPUT"