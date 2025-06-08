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
PROJECTS_LISTED_COUNT=0

echo "Fetching projects, filtering, sorting, and generating HTML..."
echo "--------------------------------------------------------------------------"

# 2. JQ PROCESSOR: This remains unchanged from your original script.
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
    "<h2>" + $current_category_name + "</h2>\n<ul class=\"project-list\">\n" +
    (map(
        "<li class=\"project-item\"><img src=\"" + ((.ProjectLogo | select(length > 0)) // "https://lf-master-project-logos-prod.s3.us-east-2.amazonaws.com/cncf.svg") + "\" alt=\"" + .Name + " Logo\" class=\"project-logo\"> " + .Name + " (<a href=\"https://zoom-lfx.platform.linuxfoundation.org/meetings/" + (.Slug | @uri) + "\">Project calendar</a>)" +
        (if .RepositoryURL and (.RepositoryURL | length > 0) then " (<a href=\"" + .RepositoryURL + "\">Project code</a>)" else "" end) +
        "</li>\n"
    ) | add) +
    "</ul>\n"
) | add
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
        ul { list-style-type: none; padding: 0; }
        li { margin-bottom: 12px; font-size: 1.1em; background-color: #ffffff; padding: 10px 15px; border-radius: 5px; box-shadow: 0 2px 4px rgba(0,0,0,0.05); display: flex; align-items: center; }
        a { color: #3498db; text-decoration: none; }
        a:hover { text-decoration: underline; color: #2980b9; }
        #search-box { width: 100%; padding: 10px; margin-bottom: 20px; border: 1px solid #ccc; border-radius: 5px; box-sizing: border-box; font-size: 1.1em; }

        /* --- CSS FOR PROJECT LOGOS HAS BEEN UPDATED TO 200x200 --- */
        .project-logo {
            width: 200px;
            height: 200px;
            vertical-align: middle;
            margin-right: 15px;
            object-fit: contain;
        }
    </style>
</head>
<body>
    <h1>CNCF Project Calendars</h1>
    <h2>Main Calendar</h2>
    <ul>
        <li><img src="https://lf-master-project-logos-prod.s3.us-east-2.amazonaws.com/cncf.svg" alt="CNCF Logo" width="200" height="200" style="vertical-align: middle; margin-right: 12px; object-fit: contain;"> CNCF Main calendar (<a href="https://zoom-lfx.platform.linuxfoundation.org/meetings/cncf">Project calendar</a>)</li>
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

    # Loop to fetch all paginated data
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

        FILTERED_JSON_STREAM=$(echo "$RESPONSE" | jq -c '.Data[] | select(.Foundation.ID == "a0941000002wBz4AAE") | {Name: .Name, Slug: .Slug, Category: .Category, ProjectLogo: .ProjectLogo, RepositoryURL: .RepositoryURL}')
        echo "$FILTERED_JSON_STREAM"

        CURRENT_PAGE_FILTERED_COUNT=$(echo "$FILTERED_JSON_STREAM" | wc -l)
        PROJECTS_LISTED_COUNT=$((PROJECTS_LISTED_COUNT + CURRENT_PAGE_FILTERED_COUNT))
        OFFSET=$((OFFSET + PROJECTS_RECEIVED_ON_PAGE))
        sleep 0.2
    done | jq -n -r "$JQ_HTML_PROCESSOR"

    # Print the HTML footer
    cat <<EOF
</body>
</html>
EOF
} > "$OUTPUT_HTML_FILE"

echo "--------------------------------------------------------------------------"
echo "Finished fetching projects and generating HTML."
echo "Total projects matching Foundation ID filter: $PROJECTS_LISTED_COUNT"
echo "HTML file generated: $OUTPUT_HTML_FILE"

# 4. SET ACTION OUTPUT: Make the path to the generated file available to other steps.
echo "html_file=${OUTPUT_HTML_FILE}" >> $GITHUB_OUTPUT
