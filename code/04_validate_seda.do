/*==============================================================================
    04_validate_seda.do
    Compares the pipeline's county estimates with the Stanford Education Data
    Archive: county means by subgroup and White-Black gaps, state by state.

    Inputs       : data/derived/proficiency_counts.dta
                   data/derived/gaps_cell_level.dta
                   data/derived/gaps_county_level.dta
                   SEDA 6.0 county long file (CS scale), downloaded to data/raw/seda
    Outputs      : data/derived/seda_validation_cells.dta (not versioned)
                   data/derived/county_means_within_state.dta
                   output/tables/seda_validation_correlations.csv
                   output/tables/seda_validation_by_state_grade.csv
                   output/logs/04_validate_seda.log
    Dependencies : hetop (SSC); an internet connection for the SEDA download;
                   acceptance of the SEDA data use agreement (run_all.do)
    Author       : Felipe Hernán Rodríguez Villalta
    Year         : 2026
==============================================================================*/

if "${root}" == "" {
    display as error "Run this script through run_all.do, which sets the scope and the paths."
    exit 198
}
if ${SEDA_ACCEPT_DUA} != 1 {
    display as error "Set SEDA_ACCEPT_DUA to 1 in run_all.do after reading the SEDA data use agreement."
    exit 1
}

capture log close step04
log using "${logs}/04_validate_seda.log", replace text name(step04)

*------------------------------------------------------------------------------
* What is compared, and why levels are not
*
* SEDA estimates county means with HETOP on the full EDFacts category counts
* and links them to the NAEP scale; its cohort-standardized (CS) metric is in
* national student-level standard deviation units. The estimates here come
* from the single proficiency cut in the public files and are standardized
* within each state, grade and year. Levels are therefore not comparable:
* within a state and grade every SEDA scale is an affine transformation of
* the state-standardized mean, so what can be checked is the ordering and the
* linear association of counties, through Pearson and Spearman correlations
* computed within states.
*
* The main pipeline standardizes each county-grade cell on its own, which
* identifies the gap between White and Black students but not the level of
* the county. For the comparison of means, HETOP is therefore refit here the
* way SEDA fits it: all counties of a state and grade enter one model, with
* common cut scores, separately for all students, White students and Black
* students.
*------------------------------------------------------------------------------

*==============================================================================
* PART A. SEDA COUNTY FILE
*==============================================================================
capture mkdir "${raw}/seda"
local seda_file "${raw}/seda/seda_county_long_cs_6.0.dta"
local seda_url  "https://stacks.stanford.edu/file/druid:xh833nn4025/seda_county_long_cs_6.0.dta"

timer clear 41
timer on 41
capture confirm file "`seda_file'"
if _rc | ${REUSE_RAW} != 1 {
    display as text "Downloading the SEDA 6.0 county file (about 178 MB) from the Stanford Digital Repository..."
    copy "`seda_url'" "`seda_file'", replace
}
else display as text "Reusing `seda_file'"
timer off 41
quietly timer list 41
display as result "SEDA file ready in " %6.1f r(t41) " seconds."
record_runtime "04_seda_download" `=r(t41)'

use "`seda_file'", clear
display as text "SEDA county long file: " _N " rows (county x subject x grade x year)."

* SEDA codes a school year by its spring; the portal by its fall.
local seda_year = ${EDF_YEAR} + 1
keep if subject == "mth" & year == `seda_year'

gen byte in_grades = 0
foreach g in $GRADES {
    quietly replace in_grades = 1 if grade == `g'
}
gen byte in_states = 0
foreach s in $STATES {
    quietly replace in_states = 1 if fips == real("`s'")
}
keep if in_grades & in_states
drop in_grades in_states
if _N == 0 {
    display as error "SEDA has no county rows for math, spring `seda_year', in the study states and grades."
    display as error "SEDA 6.0 covers school years 2008-09 to 2018-19 (spring 2009 to 2019); for other years run without step 04."
    log close step04
    exit 2000
}

keep sedacounty sedacountyname fips grade year                 ///
     cs_mn_all cs_mn_se_all cs_mn_wht cs_mn_se_wht             ///
     cs_mn_blk cs_mn_se_blk cs_mn_wbg cs_mn_se_wbg             ///
     tot_asmt_all tot_asmt_wht tot_asmt_blk
rename sedacounty     county_fips
rename sedacountyname county_name
rename year           seda_year
foreach v of varlist cs_* tot_asmt_* {
    rename `v' seda_`v'
}
label var county_name "County name (SEDA)"
display as text "SEDA rows in scope (math, spring `seda_year', study grades and states): " _N
tempfile seda
save `seda'

*==============================================================================
* PART B. COUNTY MEANS FROM HETOP ACROSS COUNTIES, WITHIN STATE AND GRADE
*==============================================================================
use "${derived}/proficiency_counts.dta", clear

tempfile ws
tempname pf
postfile `pf' int(fips grade) byte(subgroup) long(county_fips) ///
    double(mu_ws mu_ws_se sd_ws) byte(converged) using `ws', replace

timer clear 42
timer on 42
local n_fits 0
local n_fail 0
foreach s in $STATES {
    local sn = real("`s'")
    foreach g in $GRADES {
        forvalues sub = 1/3 {
            preserve
                quietly keep if fips == `sn' & grade == `g' & subgroup == `sub'
                quietly count
                local ng = r(N)
                if `ng' < 3 {
                    restore
                    continue
                }
                sort county_fips
                gen int gid = _n
                local ++n_fits
                capture quietly hetop gid n_cat, numcats(4) identify(sums)
                local rc = _rc
                local ok = (`rc' == 0)
                if `ok' local ok = (e(converged) == 1)
                if `ok' {
                    matrix _M   = e(mstar)
                    matrix _Mse = e(mstar_se)
                    matrix _S   = e(sstar)
                    forvalues i = 1/`=_N' {
                        post `pf' (`sn') (`g') (`sub') (county_fips[`i']) ///
                            (_M[`i', 1]) (_Mse[`i', 1]) (_S[`i', 1]) (1)
                    }
                }
                else {
                    local ++n_fail
                    forvalues i = 1/`=_N' {
                        post `pf' (`sn') (`g') (`sub') (county_fips[`i']) (.) (.) (.) (0)
                    }
                }
            restore
            display as text "  state `s', grade `g', subgroup `sub': " ///
                cond(`ok', "converged", "FAILED (rc `rc')") " with `ng' counties"
        }
    }
}
postclose `pf'
timer off 42
quietly timer list 42
display as result _n "Within-state HETOP: `n_fits' fits, `n_fail' failed, in " %7.1f r(t42) " seconds."
record_runtime "04_within_state_hetop" `=r(t42)'
record_runtime "04_within_state_fits" `n_fits'

use `ws', clear
label define subgrp 1 "All students" 2 "White" 3 "Black", replace
label values subgroup subgrp
label var mu_ws    "County mean, HETOP across counties within state and grade (standardized)"
label var mu_ws_se "SE of county mean"
label var sd_ws    "County SD, same model"
label_states fips
save "${derived}/county_means_within_state.dta", replace

*==============================================================================
* PART C. MERGE WITH SEDA AND CORRELATE WITHIN STATES
*==============================================================================
use "${derived}/county_means_within_state.dta", clear
keep if converged == 1
keep fips grade subgroup county_fips mu_ws mu_ws_se
reshape wide mu_ws mu_ws_se, i(fips grade county_fips) j(subgroup)
rename mu_ws1 mu_all
rename mu_ws2 mu_white
rename mu_ws3 mu_black
rename mu_ws_se1 mu_all_se
rename mu_ws_se2 mu_white_se
rename mu_ws_se3 mu_black_se

* White-Black gaps by cell from the main pipeline
merge 1:1 county_fips grade using "${derived}/gaps_cell_level.dta", ///
    keepusing(gap_wb gap_wb_se gap_direct gap_direct_se) keep(master match) nogen

merge 1:1 county_fips grade using `seda', keep(master match) nogen

gen byte has_seda_all = !missing(seda_cs_mn_all)
gen byte has_seda_gap = !missing(seda_cs_mn_wbg)
quietly count if has_seda_all
local n_seda_all = r(N)
quietly count if has_seda_gap
local n_seda_gap = r(N)
display as text _n "County-grade cells with a SEDA mean for all students: `n_seda_all' of " _N
display as text "County-grade cells with a SEDA White-Black gap: `n_seda_gap' of " _N

* Both measures are standardized within state and grade before pooling grades
* within a state, so that the grade-specific constants of the SEDA scale do
* not enter the comparison.
foreach pair in "mu_all seda_cs_mn_all" "mu_white seda_cs_mn_wht" "mu_black seda_cs_mn_blk" ///
                "gap_wb seda_cs_mn_wbg" {
    local ours : word 1 of `pair'
    local theirs : word 2 of `pair'
    foreach v in `ours' `theirs' {
        quietly bysort fips grade: egen double _m = mean(`v') if !missing(`ours') & !missing(`theirs')
        quietly bysort fips grade: egen double _s = sd(`v')   if !missing(`ours') & !missing(`theirs')
        gen double z_`v' = (`v' - _m) / _s
        drop _m _s
    }
}

label var z_mu_all          "County mean, all students (z within state-grade)"
label var z_seda_cs_mn_all  "SEDA county mean, all students (z within state-grade)"
label var z_mu_white        "County mean, White (z within state-grade)"
label var z_seda_cs_mn_wht  "SEDA county mean, White (z within state-grade)"
label var z_mu_black        "County mean, Black (z within state-grade)"
label var z_seda_cs_mn_blk  "SEDA county mean, Black (z within state-grade)"
label var z_gap_wb          "White-Black gap V (z within state-grade)"
label var z_seda_cs_mn_wbg  "SEDA White-Black gap (z within state-grade)"

gen int edf_year = ${EDF_YEAR}
label var edf_year "Portal year of the pipeline run that produced this file"
compress
save "${derived}/seda_validation_cells.dta", replace

*------------------------------------------------------------------------------
* Correlations by state (grades pooled after standardization) and overall
*------------------------------------------------------------------------------
tempname fh
file open `fh' using "${tables}/seda_validation_correlations.csv", write replace text
file write `fh' "measure,state_fips,state,cells,pearson,spearman" _n

local measures "mean_all mean_white mean_black gap"
local v_mean_all   "z_mu_all z_seda_cs_mn_all"
local v_mean_white "z_mu_white z_seda_cs_mn_wht"
local v_mean_black "z_mu_black z_seda_cs_mn_blk"
local v_gap        "z_gap_wb z_seda_cs_mn_wbg"

display as result _n "Correlations between pipeline and SEDA estimates, within states"
display as text "{hline 78}"
display as text %-12s "measure" %-18s "state" %8s "cells" %10s "pearson" %10s "spearman"
display as text "{hline 78}"
foreach m of local measures {
    local x : word 1 of `v_`m''
    local y : word 2 of `v_`m''
    quietly levelsof fips, local(stlist)
    foreach s of local stlist {
        quietly count if !missing(`x') & !missing(`y') & fips == `s'
        local n = r(N)
        if `n' < 5 continue
        quietly correlate `x' `y' if fips == `s'
        local rp = r(rho)
        quietly spearman `x' `y' if fips == `s'
        local rs = r(rho)
        local sname : label stfips `s'
        display as text %-12s "`m'" %-18s "`sname'" %8.0f `n' %10.3f `rp' %10.3f `rs'
        file write `fh' "`m',`s',`sname',`n',`rp',`rs'" _n
    }
    quietly count if !missing(`x') & !missing(`y')
    local n = r(N)
    if `n' >= 5 {
        quietly correlate `x' `y'
        local rp = r(rho)
        quietly spearman `x' `y'
        local rs = r(rho)
        display as result %-12s "`m'" %-18s "All states" %8.0f `n' %10.3f `rp' %10.3f `rs'
        file write `fh' "`m',0,All states,`n',`rp',`rs'" _n
    }
}
display as text "{hline 78}"
file close `fh'

*------------------------------------------------------------------------------
* Pearson correlation by state and grade, raw measures (no standardization
* needed within a single state-grade cell)
*------------------------------------------------------------------------------
tempname fg
file open `fg' using "${tables}/seda_validation_by_state_grade.csv", write replace text
file write `fg' "state_fips,state,grade,cells_mean,pearson_mean_all,cells_gap,pearson_gap" _n
quietly levelsof fips, local(stlist)
foreach s of local stlist {
    local sname : label stfips `s'
    foreach g in $GRADES {
        quietly count if !missing(mu_all) & !missing(seda_cs_mn_all) & fips == `s' & grade == `g'
        local n1 = r(N)
        local r1 = .
        if `n1' >= 5 {
            quietly correlate mu_all seda_cs_mn_all if fips == `s' & grade == `g'
            local r1 = r(rho)
        }
        quietly count if !missing(gap_wb) & !missing(seda_cs_mn_wbg) & fips == `s' & grade == `g'
        local n2 = r(N)
        local r2 = .
        if `n2' >= 5 {
            quietly correlate gap_wb seda_cs_mn_wbg if fips == `s' & grade == `g'
            local r2 = r(rho)
        }
        file write `fg' "`s',`sname',`g',`n1',`r1',`n2',`r2'" _n
    }
}
file close `fg'

*------------------------------------------------------------------------------
* County-level gaps: pooled V against the precision-weighted mean of SEDA's
* grade gaps, for the counties in both
*------------------------------------------------------------------------------
preserve
    keep if !missing(seda_cs_mn_wbg) & !missing(gap_wb)
    gen double _w = 1 / (seda_cs_mn_se_wbg^2)
    collapse (mean) seda_gap_pooled = seda_cs_mn_wbg [aweight = _w], by(county_fips fips)
    merge 1:1 county_fips using "${derived}/gaps_county_level.dta", ///
        keepusing(gap_wb_pooled gap_wb_pooled_se) keep(match) nogen
    quietly correlate gap_wb_pooled seda_gap_pooled
    local rp = r(rho)
    quietly spearman gap_wb_pooled seda_gap_pooled
    local rs = r(rho)
    display as result _n "Pooled county gaps against SEDA's grade-averaged gaps, " _N " counties: " ///
        "Pearson " %6.3f `rp' ", Spearman " %6.3f `rs'
    file open `fh' using "${tables}/seda_validation_correlations.csv", write append text
    file write `fh' "gap_pooled_county,0,All states,`=_N',`rp',`rs'" _n
    file close `fh'
    label var seda_gap_pooled "SEDA White-Black gap, precision-weighted mean over grades (CS units)"
    save "${derived}/seda_validation_counties.dta", replace
restore

display as result _n "Validation complete."
log close step04
