/*==============================================================================
    05_figures_tables.do
    Draws the four figures of the brief, including the county map, and writes
    the summary tables used by the brief and the replication manual.

    Inputs       : data/derived/gaps_county_level.dta, gaps_cell_level.dta,
                   hetop_estimates.dta, seda_validation_cells.dta,
                   output/tables/exclusions_district_cells.dta,
                   output/tables/seda_validation_correlations.csv;
                   Census cartographic boundary file (downloaded to data/raw/shapes)
    Outputs      : output/figures/figure1_county_gaps, figure3_gap_poverty,
                   figure4_seda_validation, figure2_county_map (svg and png);
                   copies in docs/figures; output/tables/county_gaps.csv and
                   .html, state_summary.html, exclusions_summary.html,
                   seda_correlations.html, convergence.html;
                   data/derived/county_names.dta; output/logs/05_figures_tables.log
    Dependencies : grmap and spshape2dta (shipped with Stata 15 and later)
    Author       : Felipe Hernán Rodríguez Villalta
    Year         : 2026
==============================================================================*/

if "${root}" == "" {
    display as error "Run this script through run_all.do, which sets the scope and the paths."
    exit 198
}

capture log close step05
log using "${logs}/05_figures_tables.log", replace text name(step05)

*------------------------------------------------------------------------------
* Colors, one per state, from the palette used in the brief
*------------------------------------------------------------------------------
local palette `" "42 120 214" "235 104 52" "27 175 122" "237 161 0" "232 123 164" "74 58 167" "0 131 0" "'
local i 0
foreach s in $STATES {
    local ++i
    local col_`=real("`s'")' : word `=mod(`i' - 1, 7) + 1' of `palette'
}
local gray "137 135 129"
local ink  "11 11 11"

* html_table writes the data in memory as an HTML table fragment: variable
* labels as headers, display formats for numbers, value labels where defined.
capture program drop html_table
program define html_table
    syntax using/, [Title(string)]
    tempname fh
    file open `fh' using `"`using'"', write replace text
    if `"`title'"' != "" file write `fh' `"<p class="tbl-title">`title'</p>"' _n
    file write `fh' `"<table class="dt">"' _n "<thead><tr>"
    foreach v of varlist _all {
        local lab : variable label `v'
        if `"`lab'"' == "" local lab "`v'"
        file write `fh' `"<th>`lab'</th>"'
    }
    file write `fh' "</tr></thead>" _n "<tbody>" _n
    forvalues i = 1/`=_N' {
        file write `fh' "<tr>"
        foreach v of varlist _all {
            capture confirm string variable `v'
            if !_rc {
                local val = `v'[`i']
            }
            else {
                local vl : value label `v'
                if "`vl'" != "" {
                    local val : label `vl' `=`v'[`i']'
                }
                else {
                    local fmt : format `v'
                    local val : display `fmt' `v'[`i']
                    local val = trim("`val'")
                }
            }
            file write `fh' "<td>`val'</td>"
        }
        file write `fh' "</tr>" _n
    }
    file write `fh' "</tbody></table>" _n
    file close `fh'
end

*==============================================================================
* PART A. COUNTY NAMES AND BOUNDARIES FROM THE CENSUS BUREAU
*
* The cartographic boundary file (1:20,000,000) is small and gives both the
* polygons for the map and the county names used in the tables. The 2018
* vintage matches the school year.
*==============================================================================
capture mkdir "${raw}/shapes"
local shp_url "https://www2.census.gov/geo/tiger/GENZ2018/shp/cb_2018_us_county_20m.zip"
capture confirm file "${raw}/shapes/cb_2018_us_county_20m.zip"
if _rc | ${REUSE_RAW} != 1 {
    display as text "Downloading the Census county boundary file (about 0.9 MB)..."
    capture copy "`shp_url'" "${raw}/shapes/cb_2018_us_county_20m.zip", replace
    if _rc {
        * The Census Bureau's server does not answer Stata's HTTP client; curl,
        * present on macOS and most Linux systems, fetches the same file.
        display as text "  copy could not reach the Census server; trying curl"
        shell curl -fsSL --retry 3 -o "${raw}/shapes/cb_2018_us_county_20m.zip" "`shp_url'"
    }
}
capture confirm file "${raw}/shapes/cb_2018_us_county_20m.zip"
local have_shapes = (_rc == 0)

tempfile shape_attr
if `have_shapes' {
    cd "${raw}/shapes"
    capture quietly unzipfile cb_2018_us_county_20m.zip, replace
    if !_rc capture spshape2dta cb_2018_us_county_20m, replace saving(counties)
    if _rc {
        display as error "The boundary file could not be unpacked or translated; the map is skipped."
        local have_shapes 0
    }
    cd "${root}"
}
if `have_shapes' {
    use "${raw}/shapes/counties.dta", clear
    gen long county_fips = real(GEOID)
    gen int  fips        = real(STATEFP)
    label_states fips
    keep _ID _CX _CY county_fips fips NAME
    rename NAME county_name
    label var county_name "County"
    label var county_fips "County FIPS code"
    label var fips        "State"
    preserve
        keep county_fips fips county_name
        sort county_fips
        save "${derived}/county_names.dta", replace
    restore
    save `shape_attr'
}
else {
    display as error "The Census boundary file is not available: county names fall back to FIPS codes and the map is skipped."
    use "${derived}/gaps_county_level.dta", clear
    keep county_fips fips
    gen str20 county_name = "FIPS " + string(county_fips, "%05.0f")
    label var county_name "County"
    sort county_fips
    save "${derived}/county_names.dta", replace
}

*==============================================================================
* PART B. COUNTY TABLE
*==============================================================================
use "${derived}/gaps_county_level.dta", clear
merge 1:1 county_fips using "${derived}/county_names.dta", keep(master match) nogen
replace county_name = "FIPS " + string(county_fips, "%05.0f") if missing(county_name)

gen double ci_lo        = gap_wb_pooled - 1.96 * gap_wb_pooled_se
gen double ci_hi        = gap_wb_pooled + 1.96 * gap_wb_pooled_se
gen double ci_lo_direct = gap_wb_pooled - 1.96 * gap_wb_pooled_se_direct
gen double ci_hi_direct = gap_wb_pooled + 1.96 * gap_wb_pooled_se_direct

* The reference line in Figure 1 is the pooled gap of the random-intercept
* model at grade 6 (its fixed part), written by step 03
preserve
    import delimited using "${tables}/pooling_summary.csv", clear varnames(1) stringcols(1)
    quietly levelsof value if statistic == "grand_gap_grade6", local(gm)
    local gap_mean = `gm'
restore
quietly summarize gap_wb_pooled, detail
local gap_p10 = r(p10)
local gap_p50 = r(p50)
local gap_p90 = r(p90)
display as result "Pooled gaps: model grand mean at grade 6 " %6.3f `gap_mean' ///
    ", median county " %6.3f `gap_p50' ", 10th to 90th percentile " %6.3f `gap_p10' " to " %6.3f `gap_p90'

sort gap_wb_pooled
gen int rank = _n

preserve
    keep fips county_name gap_wb_pooled ci_lo ci_hi ci_lo_direct ci_hi_direct ///
         n_black_mean n_white_mean poverty_rate share_black n_districts county_fips
    order fips county_name gap_wb_pooled ci_lo ci_hi ci_lo_direct ci_hi_direct ///
          n_black_mean n_white_mean poverty_rate share_black n_districts county_fips
    gsort fips -gap_wb_pooled
    format gap_wb_pooled ci_lo ci_hi ci_lo_direct ci_hi_direct %6.2f
    format n_black_mean n_white_mean %8.0f
    format poverty_rate share_black %5.2f
    format n_districts %3.0f
    label var fips          "State"
    label var county_name   "County"
    label var gap_wb_pooled "Gap (V)"
    label var ci_lo         "95% low, HETOP"
    label var ci_hi         "95% high, HETOP"
    label var ci_lo_direct  "95% low, binomial"
    label var ci_hi_direct  "95% high, binomial"
    label var n_black_mean  "Black tested per grade"
    label var n_white_mean  "White tested per grade"
    label var poverty_rate  "Child poverty"
    label var share_black   "Black share"
    label var n_districts   "Districts"
    label var county_fips   "FIPS"
    export delimited using "${tables}/county_gaps.csv", replace
    html_table using "${tables}/county_gaps.html"
restore

*==============================================================================
* PART C. FIGURE 1. County gaps with intervals, ordered, pooled mean marked
*
* Thick bars are the 95% intervals from the HETOP standard errors; thin bars
* extend them to the binomial-based intervals. Colors identify states.
*==============================================================================
local layers ""
foreach s in $STATES {
    local sn = real("`s'")
    local sname : label stfips `sn'
    local layers `layers' (rspike ci_lo_direct ci_hi_direct rank if fips == `sn', lcolor("`col_`sn''%35") lwidth(vthin))
    local layers `layers' (rcap ci_lo ci_hi rank if fips == `sn', lcolor("`col_`sn''%80") lwidth(thin) msize(zero))
}
* Point layers, one per state, listed after the interval layers so the legend
* can refer to them
local points ""
local npre = 2 * `: word count $STATES'
local legend_order ""
local k `npre'
foreach s in $STATES {
    local sn = real("`s'")
    local sname : label stfips `sn'
    local ++k
    local points `points' (scatter gap_wb_pooled rank if fips == `sn', mcolor("`col_`sn''") msymbol(circle) msize(vsmall))
    local legend_order `legend_order' `k' "`sname'"
}

twoway `layers' `points',                                                      ///
    yline(0, lpattern(dash) lcolor("`gray'"))                                 ///
    yline(`gap_mean', lpattern(solid) lcolor("`ink'") lwidth(vthin))            ///
    ytitle("White-Black gap, V (standard deviation units)")                     ///
    xtitle("Counties, ordered by estimated gap")                                ///
    xlabel(none) xscale(range(0 `=_N + 1'))                                     ///
    ylabel(, angle(horizontal) format(%3.1f) grid glcolor(gs15))                ///
    text(`=`gap_mean' + 0.05' 8 "pooled estimate, all counties: `: display %4.2f `gap_mean''", ///
         placement(east) size(small) color("`ink'"))                            ///
    legend(order(`legend_order') rows(1) size(small) region(lstyle(none)) position(6)) ///
    graphregion(color(white) margin(small)) plotregion(margin(small))           ///
    scheme(s1color) name(fig1, replace)
graph export "${figures}/figure1_county_gaps.svg", replace width(1100)
graph export "${figures}/figure1_county_gaps.png", replace width(1600)

*==============================================================================
* PART D. FIGURE 3. Gap against child poverty, precision-weighted fit
*==============================================================================
quietly regress gap_wb_pooled poverty_rate [pweight = prec_county], robust
local b_pov  = _b[poverty_rate]
local se_pov = _se[poverty_rate]
quietly correlate gap_wb_pooled poverty_rate [aweight = prec_county]
local r_pov = r(rho)

local points ""
local legend_order ""
local k 0
foreach s in $STATES {
    local sn = real("`s'")
    local sname : label stfips `sn'
    local ++k
    local points `points' (scatter gap_wb_pooled poverty_rate if fips == `sn' [aweight = prec_county], mcolor("`col_`sn''%45") mlcolor("`col_`sn''") msymbol(circle) msize(*0.55))
    local legend_order `legend_order' `k' "`sname'"
}
twoway `points'                                                                 ///
    (lfit gap_wb_pooled poverty_rate [pweight = prec_county], lcolor("`ink'") lwidth(medthin)), ///
    yline(0, lpattern(dash) lcolor("`gray'"))                                 ///
    ytitle("White-Black gap, V (standard deviation units)")                     ///
    xtitle("Child poverty rate, ages 5 to 17 (SAIPE)")                          ///
    xlabel(, format(%3.2f)) ylabel(, angle(horizontal) format(%3.1f) grid glcolor(gs15)) ///
    legend(order(`legend_order') rows(1) size(small) region(lstyle(none)) position(6)) ///
    note("Marker area proportional to the precision of the county estimate. Precision-weighted fit: slope `: display %5.2f `b_pov'' (robust SE `: display %4.2f `se_pov''), weighted r = `: display %4.2f `r_pov''.", size(vsmall)) ///
    graphregion(color(white) margin(small)) plotregion(margin(small))           ///
    scheme(s1color) name(fig2, replace)
graph export "${figures}/figure3_gap_poverty.svg", replace width(1100)
graph export "${figures}/figure3_gap_poverty.png", replace width(1600)

*==============================================================================
* PART E. FIGURE 4. Validation against SEDA: county means and gaps
*==============================================================================
local have_seda 0
capture confirm file "${derived}/seda_validation_cells.dta"
if !_rc {
    use "${derived}/seda_validation_cells.dta", clear
    capture confirm variable edf_year
    if !_rc {
        quietly summarize edf_year
        if r(min) == ${EDF_YEAR} local have_seda 1
    }
}
if !`have_seda' {
    display as error "No SEDA validation file for portal year ${EDF_YEAR} in data/derived (step 04 did not run for this scope); Figure 4 is skipped."
    tempname fh
    file open `fh' using "${tables}/seda_correlations.html", write replace text
    file write `fh' `"<p class="tbl-title">The validation against SEDA did not run for this scope (step 04).</p>"' _n
    file close `fh'
}
else {

    * Overall correlations, taken from the table written by step 04
    preserve
        import delimited using "${tables}/seda_validation_correlations.csv", clear varnames(1) stringcols(3)
        quietly keep if state == "All states"
        foreach m in mean_all gap {
            quietly levelsof pearson  if measure == "`m'", local(p)
            quietly levelsof spearman if measure == "`m'", local(s)
            quietly levelsof cells    if measure == "`m'", local(n)
            local rp_`m' : display %4.2f `p'
            local rs_`m' : display %4.2f `s'
            local n_`m' = `n'
        }
    restore

    foreach panel in means gaps {
        if "`panel'" == "means" {
            local x z_seda_cs_mn_all
            local y z_mu_all
            local xt "SEDA county mean, all students"
            local yt "County mean from this pipeline"
            local ttl "A. County means, all students"
            local ann "r = `rp_mean_all', Spearman = `rs_mean_all', `n_mean_all' county-grade cells"
        }
        else {
            local x z_seda_cs_mn_wbg
            local y z_gap_wb
            local xt "SEDA White-Black gap"
            local yt "White-Black gap V from this pipeline"
            local ttl "B. White-Black gaps"
            local ann "r = `rp_gap', Spearman = `rs_gap', `n_gap' county-grade cells"
        }
        local points ""
        foreach s in $STATES {
            local sn = real("`s'")
            local points `points' (scatter `y' `x' if fips == `sn', mcolor("`col_`sn''%60") msymbol(circle) msize(small))
        }
        twoway `points' (lfit `y' `x', lcolor("`ink'") lwidth(medthin)),          ///
            title("`ttl'", size(medsmall) position(11) justification(left) color("`ink'")) ///
            subtitle("`ann'", size(small) position(11) justification(left) color("`gray'")) ///
            xtitle("`xt' (z within state and grade)", size(small))                 ///
            ytitle("`yt' (z within state and grade)", size(small))                 ///
            xlabel(-3(1)3, format(%2.0f)) ylabel(-3(1)3, angle(horizontal) format(%2.0f) grid glcolor(gs15)) ///
            legend(off) aspectratio(1)                                           ///
            graphregion(color(white) margin(small)) plotregion(margin(small))     ///
            scheme(s1color) name(fig3`panel', replace)
    }
    graph combine fig3means fig3gaps, rows(1) graphregion(color(white)) ///
        xsize(10) ysize(5.2) name(fig3, replace)
    * PNG only: an SVG would carry the standardized SEDA values as point
    * coordinates, which the SEDA data use agreement does not allow to publish
    graph export "${figures}/figure4_seda_validation.png", replace width(1600)

    * SEDA correlation table for the documents
    import delimited using "${tables}/seda_validation_correlations.csv", clear varnames(1) stringcols(3)
    keep if inlist(measure, "mean_all", "mean_white", "mean_black", "gap")
    gen byte order = cond(measure == "mean_all", 1, cond(measure == "mean_white", 2, cond(measure == "mean_black", 3, 4)))
    gen str28 measure_label = ""
    replace measure_label = "County mean, all students" if measure == "mean_all"
    replace measure_label = "County mean, White students" if measure == "mean_white"
    replace measure_label = "County mean, Black students" if measure == "mean_black"
    replace measure_label = "White-Black gap" if measure == "gap"
    gsort order state_fips
    keep measure_label state cells pearson spearman
    order measure_label state cells pearson spearman
    format pearson spearman %5.3f
    format cells %5.0f
    label var measure_label "Measure"
    label var state "State"
    label var cells "County-grade cells"
    label var pearson "Pearson"
    label var spearman "Spearman"
    html_table using "${tables}/seda_correlations.html"
}

*==============================================================================
* PART F. FIGURE 2. Map of the counties covered, shaded by the pooled gap
*
* Counties in the study states without an estimate are drawn in light gray:
* those outside the sample (fewer than MIN_CELL_N Black test takers in some
* grade) and sample counties with no White cell of MIN_CELL_N in any grade.
* Every mapped value rests on cells of at least MIN_CELL_N students.
*==============================================================================
if ${MAKE_MAP} == 1 & `have_shapes' {
    capture grmap, activate
    use `shape_attr', clear
    merge 1:1 county_fips using "${derived}/gaps_county_level.dta", ///
        keepusing(gap_wb_pooled) keep(master match) nogen
    gen byte in_scope = 0
    foreach s in $STATES {
        quietly replace in_scope = 1 if fips == real("`s'")
    }
    * Five quantile classes with readable labels
    quietly summarize gap_wb_pooled if in_scope == 1
    local gmin : display %4.2f r(min)
    local gmax : display %4.2f r(max)
    _pctile gap_wb_pooled if in_scope == 1 & !missing(gap_wb_pooled), nq(5)
    forvalues k = 1/4 {
        local q`k' = r(r`k')
        local l`k' : display %4.2f `q`k''
    }
    gen byte gap_class = 1 + (gap_wb_pooled >= `q1') + (gap_wb_pooled >= `q2') ///
        + (gap_wb_pooled >= `q3') + (gap_wb_pooled >= `q4') if !missing(gap_wb_pooled)
    label define gapcl 1 "`gmin' to `l1'" 2 "`l1' to `l2'" 3 "`l2' to `l3'" ///
        4 "`l3' to `l4'" 5 "`l4' to `gmax'", replace
    label values gap_class gapcl

    * grmap finds the coordinates file through the name spset recorded, so it
    * runs from the folder that holds counties_shp.dta
    cd "${raw}/shapes"
    grmap gap_class if in_scope == 1, clmethod(unique)                           ///
        fcolor(Blues) ocolor(white ...) osize(vthin ...)                         ///
        ndfcolor(gs14) ndocolor(white) ndsize(vthin) ndlabel("No estimate")      ///
        legtitle("Pooled White-Black gap, V (quintiles)")                        ///
        legend(size(small) position(5) ring(0) region(lstyle(none)))             ///
        graphregion(color(white)) name(fig4, replace)
    cd "${root}"
    graph export "${figures}/figure2_county_map.svg", replace width(1100)
    graph export "${figures}/figure2_county_map.png", replace width(1600)
}
else display as text "Figure 2 skipped (MAKE_MAP is 0 or the boundary file is missing)."

*==============================================================================
* PART G. SUMMARY TABLES FOR THE DOCUMENTS
*==============================================================================

*---- State summary -----------------------------------------------------------
use "${derived}/gaps_county_level.dta", clear
gen double _w = prec_county
collapse (count) counties = county_fips (mean) gap_mean = gap_wb_pooled ///
         (min) gap_min = gap_wb_pooled (max) gap_max = gap_wb_pooled ///
         (mean) poverty_mean = poverty_rate share_black_mean = share_black ///
         n_black_mean n_white_mean [aweight = _w], by(fips)
label_states fips
format gap_mean gap_min gap_max %5.2f
format poverty_mean share_black_mean %5.2f
format n_black_mean n_white_mean %7.0f
format counties %4.0f
label var fips             "State"
label var counties         "Counties"
label var gap_mean         "Mean gap (V), precision weighted"
label var gap_min          "Smallest"
label var gap_max          "Largest"
label var poverty_mean     "Child poverty"
label var share_black_mean "Black share of enrollment"
label var n_black_mean     "Black tested per grade"
label var n_white_mean     "White tested per grade"
order fips counties gap_mean gap_min gap_max poverty_mean share_black_mean n_black_mean n_white_mean
html_table using "${tables}/state_summary.html"
export delimited using "${tables}/state_summary.csv", replace

*---- Exclusions at the district level ----------------------------------------
use "${tables}/exclusions_district_cells.dta", clear
label_states fips
* Share of tested Black students in cells dropped for size, by state
preserve
    keep if subgroup == 3
    gen double kept_students   = students * (excl_reason == 0)
    gen double small_students  = students * (excl_reason == 3)
    gen long   suppressed_rows = rows * (excl_reason == 1)
    gen long   small_rows      = rows * (excl_reason == 3)
    gen long   kept_rows       = rows * (excl_reason == 0)
    collapse (sum) rows kept_rows suppressed_rows small_rows kept_students small_students, by(fips)
    gen double share_small = small_students / (kept_students + small_students)
    format share_small %5.3f
    format rows kept_rows suppressed_rows small_rows %6.0f
    format kept_students small_students %9.0f
    label var fips            "State"
    label var rows            "District-grade rows, Black"
    label var kept_rows       "Kept"
    label var suppressed_rows "Suppressed by EDFacts"
    label var small_rows      "Fewer than ${MIN_CELL_N} tested"
    label var kept_students   "Black students tested in kept rows"
    label var small_students  "Black students tested in small rows"
    label var share_small     "Share of Black students excluded by the size rule"
    order fips rows kept_rows suppressed_rows small_rows kept_students small_students share_small
    html_table using "${tables}/exclusions_summary.html"
    export delimited using "${tables}/exclusions_summary.csv", replace
restore

*---- HETOP convergence --------------------------------------------------------
import delimited using "${tables}/hetop_convergence.csv", clear varnames(1)
label_states fips
label var fips       "State"
label var cells      "County-grade cells"
label var converged  "Converged"
label var incomplete "Incomplete (a subgroup missing)"
label var failed     "Failed or not converged"
format cells converged incomplete failed %5.0f
html_table using "${tables}/convergence.html"

*==============================================================================
* PART H. COPIES OF THE FIGURES FOR THE DOCUMENTS
*==============================================================================
foreach f in figure1_county_gaps figure2_county_map figure3_gap_poverty figure4_seda_validation {
    foreach ext in svg png {
        capture confirm file "${figures}/`f'.`ext'"
        if !_rc copy "${figures}/`f'.`ext'" "${docs}/figures/`f'.`ext'", replace
    }
}

display as result _n "Figures and tables complete."
log close step05
