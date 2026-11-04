*! scrubdta version 1.0.0  2026  Felipe Hernán Rodríguez Villalta
/*==============================================================================
    scrubdta.ado
    Zeroes the unused bytes of the fixed-width name, format and label fields
    of a Stata dataset file, which Stata fills with whatever its memory held
    when the file was written (fragments of earlier commands and paths).

    Inputs       : one .dta file in format 118 (Stata 14 to 18, up to 32,767
                   variables), named after using
    Outputs      : the same file, rewritten in place with the same size and
                   content; r(bytes) holds the number of bytes set to zero
    Dependencies : none (Mata only)
    Author       : Felipe Hernán Rodríguez Villalta
    Year         : 2026
==============================================================================*/
program define scrubdta, rclass
    version 17
    syntax using/
    confirm file `"`using'"'
    tempname nb
    mata: _scrubdta_file(`"`using'"', "`nb'")
    return scalar bytes = scalar(`nb')
end

mata:
mata set matastrict on

// a string of n binary zeros
string scalar _scrubdta_zeros(real scalar n)
{
    string scalar z
    real scalar i
    z = ""
    for (i = 1; i <= n; i++) z = z + char(0)
    return(z)
}

// an 8-byte unsigned integer stored least significant byte first, read as two
// 4-byte halves because bufio() reads integers of at most 4 bytes
real scalar _scrubdta_u64(real colvector C, string scalar s, real scalar off)
{
    return(bufget(C, s, off, "%4bu") + bufget(C, s, off + 4, "%4bu") * 4294967296)
}

// Sets to zero the bytes that follow the first binary zero of a fixed-width
// field of w bytes starting at 0-based offset start; returns the number of
// bytes changed (0 when the field is already clean or has no terminator).
real scalar _scrubdta_field(real scalar fh, string scalar s,
                            real scalar start, real scalar w)
{
    string scalar fld
    real scalar nul
    fld = substr(s, start + 1, w)
    nul = strpos(fld, char(0))
    if (nul == 0 | nul == w) return(0)
    if (substr(fld, nul + 1, w - nul) == _scrubdta_zeros(w - nul)) return(0)
    fseek(fh, start + nul, -1)
    fwrite(fh, _scrubdta_zeros(w - nul))
    return(w - nul)
}

// Format 118: tagged sections whose 0-based offsets are listed in <map>.
// Fixed-width fields: variable names (129 bytes), formats (57), value label
// names (129), variable labels (321), the two name fields of each
// characteristic (129 each) and the name of each value label (129, followed
// by 3 padding bytes). Everything else is length-prefixed and left untouched.
void _scrubdta_file(string scalar fn, string scalar result)
{
    real scalar fh, size, K, i, j, p, len, total, kpos, mpos
    real rowvector off, widths, idx
    string rowvector tags
    string scalar s
    real colvector C

    fh = fopen(fn, "rw")
    fseek(fh, 0, 1)
    size = ftell(fh)
    fseek(fh, 0, -1)
    s = fread(fh, size)
    if (strlen(s) != size) _error("scrubdta: could not read the whole file")
    if (substr(s, 1, 11) != "<stata_dta>") _error("scrubdta: not a .dta file in a tagged format")
    if (strpos(s, "<release>118</release>") == 0) _error("scrubdta: only format 118 is supported")
    if (strpos(s, "<byteorder>LSF</byteorder>") == 0) _error("scrubdta: only LSF byte order is supported")

    C = bufio()
    bufbyteorder(C, 2)

    kpos = strpos(s, "<K>")
    K = bufget(C, s, kpos + 2, "%2bu")

    mpos = strpos(s, "<map>")
    off = J(1, 14, .)
    for (i = 1; i <= 14; i++) off[i] = _scrubdta_u64(C, s, mpos + 4 + 8 * (i - 1))
    if (off[1] != 0 | off[2] != mpos - 1 | off[14] != size) _error("scrubdta: the file map does not match the file")

    total = 0
    tags   = ("<varnames>", "<formats>", "<value_label_names>", "<variable_labels>")
    widths = (129, 57, 129, 321)
    idx    = (4, 6, 7, 8)
    for (j = 1; j <= 4; j++) {
        p = off[idx[j]]
        if (substr(s, p + 1, strlen(tags[j])) != tags[j]) _error("scrubdta: unexpected section tag")
        p = p + strlen(tags[j])
        for (i = 1; i <= K; i++) {
            total = total + _scrubdta_field(fh, s, p + (i - 1) * widths[j], widths[j])
        }
    }

    p = off[9] + strlen("<characteristics>")
    while (substr(s, p + 1, 4) == "<ch>") {
        len = bufget(C, s, p + 4, "%4bu")
        total = total + _scrubdta_field(fh, s, p + 8, 129)
        total = total + _scrubdta_field(fh, s, p + 8 + 129, 129)
        p = p + 8 + len + 5
    }
    if (substr(s, p + 1, 18) != "</characteristics>") _error("scrubdta: characteristics block not parsed")

    p = off[12] + strlen("<value_labels>")
    while (substr(s, p + 1, 5) == "<lbl>") {
        len = bufget(C, s, p + 5, "%4bu")
        total = total + _scrubdta_field(fh, s, p + 9, 129)
        if (substr(s, p + 9 + 129 + 1, 3) != _scrubdta_zeros(3)) {
            fseek(fh, p + 9 + 129, -1)
            fwrite(fh, _scrubdta_zeros(3))
            total = total + 3
        }
        p = p + 9 + 129 + 3 + len + 6
    }
    if (substr(s, p + 1, 15) != "</value_labels>") _error("scrubdta: value label block not parsed")

    fclose(fh)
    st_numscalar(result, total)
}
end
