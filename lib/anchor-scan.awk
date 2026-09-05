# Literal identity first, line syntax second. Never extract paths with a regex:
# punctuation in real paths otherwise splits a citation into another file.
BEGIN {
    path = ENVIRON["CADRE_ANCHOR_PATH"]
    basename = ENVIRON["CADRE_ANCHOR_BASENAME"]
    nblockers = split(ENVIRON["CADRE_ANCHOR_BLOCKERS"], blockers, "\n")
    n = split(ENVIRON["CADRE_ANCHOR_PATCH"], patch, "\n")
    for (i = 1; i <= n; i++) {
        if (patch[i] !~ /^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/) continue
        split(patch[i], fields, " ")
        # An unlabelled citation may refer to either side. A zero-length side
        # has NO lines; its insertion/deletion point must not count as a hunk.
        for (j = 2; j <= 3; j++) {
            count = split(substr(fields[j], 2), span, ",")
            len = count == 1 ? 1 : span[2] + 0
            if (len > 0) { starts[++hunks] = span[1] + 0; ends[hunks] = span[1] + len - 1 }
        }
    }
}
function scan(text, name,    pos,offset,before,tail,anchor,nums,count,first,last,k,overlap,after,blocked,start,ending) {
    offset = 1
    while ((pos = index(substr(text, offset), name)) > 0) {
        pos += offset - 1
        before = pos == 1 ? "" : substr(text, pos - 1, 1)
        offset = pos + length(name)
        # Deliberately narrow delimiters: a slash or filename punctuation is
        # not a boundary. Unsupported wrapping is unavailable, not a guess.
        if (before != "" && before !~ /[[:space:]`"']/) continue
        if (before ~ /[`"']/ && pos > 2 && substr(text, pos - 2, 1) !~ /[[:space:]]/) continue
        blocked = 0
        for (k = 1; k <= nblockers; k++) {
            start = offset - length(blockers[k])
            if (length(blockers[k]) > length(name) && start > 0 &&
                substr(text, start, length(blockers[k])) == blockers[k]) blocked = 1
        }
        if (blocked) continue
        tail = substr(text, offset)
        if (!match(tail, /^:[0-9]+(-[0-9]+)?/) && !match(tail, /^#L[0-9]+(-L?[0-9]+)?/)) continue
        anchor = substr(tail, 1, RLENGTH)
        ending = substr(tail, RLENGTH + 1)
        # Whitelist endings: an unknown continuation (including Unicode range
        # separators) must not turn an unsupported range into a point citation.
        # Check the whole suffix up to whitespace, so ':2..30' or ':2,30'
        # cannot slip through merely because the first character is prose punctuation.
        for (k = 1; k <= length(ending); k++) {
            after = substr(ending, k, 1)
            if (after ~ /[[:space:]]/) break
            if (!index("`\"'.,;!?)]}", after)) { blocked = 1; break }
        }
        if (blocked) continue
        nums = anchor
        gsub(/[:#L]/, "", nums)
        count = split(nums, range, "-")
        first = range[1] + 0; last = count == 1 ? first : range[2] + 0
        if (first < 1 || last < first || !hunks) continue
        # Any overlap is enough: checking only a range's start over-accuses.
        overlap = 0
        for (k = 1; k <= hunks; k++)
            if (first <= ends[k] && last >= starts[k]) overlap = 1
        checked++
        if (!overlap) {
            drift++
            list = list (list == "" ? "" : ", ") path anchor
        }
    }
}
{
    # Root paths that share a basename cannot identify a file either.
    if (path != basename || unique == 1) scan($0, path)
    if (unique == 1 && path != basename) scan($0, basename)
}
END { printf "%d\t%d\t%s\n", checked, drift, list }
