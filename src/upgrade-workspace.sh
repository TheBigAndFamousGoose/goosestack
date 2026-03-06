#!/bin/bash
# GooseStack workspace merge helpers

# Append missing sections from source to target based on "## " headings.
# Each appended section is wrapped with an HTML comment marker so upgrades are traceable.
append_missing_sections() {
    local source_file="$1"
    local target_file="$2"
    local marker="${3:-GooseStack upgrade}"

    if [[ ! -f "$source_file" ]]; then
        return 1
    fi

    # If target does not exist yet, seed it directly from source.
    if [[ ! -f "$target_file" ]]; then
        cp "$source_file" "$target_file"
        return 0
    fi

    local headings=()
    while IFS= read -r heading; do
        [[ -n "$heading" ]] && headings+=("$heading")
    done < <(awk '/^##[[:space:]]+/ {sub(/^##[[:space:]]+/, "", $0); print}' "$source_file")

    local target_headings=()
    while IFS= read -r heading; do
        [[ -n "$heading" ]] && target_headings+=("$heading")
    done < <(awk '/^##[[:space:]]+/ {sub(/^##[[:space:]]+/, "", $0); print}' "$target_file")

    local appended=false
    if [[ ${#headings[@]} -eq 0 ]]; then
        return 0
    fi
    local heading
    for heading in "${headings[@]}"; do
        local exists=false
        local target_heading
        for target_heading in ${target_headings[@]+"${target_headings[@]}"}; do
            if [[ "$target_heading" == "$heading" ]]; then
                exists=true
                break
            fi
        done

        if [[ "$exists" == "true" ]]; then
            continue
        fi

        local section
        section=$(awk -v h="$heading" '
            BEGIN {in_section=0}
            $0 ~ "^##[[:space:]]+" h "[[:space:]]*$" {in_section=1; print; next}
            in_section && $0 ~ /^##[[:space:]]+/ {exit}
            in_section {print}
        ' "$source_file")

        if [[ -n "$section" ]]; then
            {
                echo
                echo "<!-- Added by ${marker}: ## ${heading} -->"
                echo "$section"
            } >> "$target_file"
            appended=true
        fi
    done

    [[ "$appended" == "true" ]] && return 2
    return 0
}
