/*==============================================================================
    03_estimate_gaps.do
    Fits HETOP to every county-grade cell, computes White-Black gaps with
    delta-method standard errors, pools them to one gap per county and
    estimates the regression ladder on county covariates.

    Inputs       : data/derived/proficiency_counts.dta
                   data/derived/county_covariates.dta
    Outputs      : data/derived/hetop_estimates.dta (one row per cell-subgroup)
                   data/derived/gaps_cell_level.dta  (one row per county-grade)
                   data/derived/gaps_county_level.dta (one row per county)
                   output/tables/table1_descriptives.html and .tex
                   output/tables/table2_gap_regression.html and .tex
                   output/tables/hetop_convergence.csv
                   output/tables/se_comparison.csv
                   output/logs/03_estimate_gaps.log
    Dependencies : hetop (SSC), estout (SSC); gapci from code/ado
    Author       : Felipe Hernán Rodríguez Villalta
    Year         : 2026
==============================================================================*/

if "${root}" == "" {
    display as error "Run this script through run_all.do, which sets the scope and the paths."
    exit 198
}

capture log close step03
log using "${logs}/03_estimate_gaps.log", replace text name(step03)

*==============================================================================
* PART 1. MATA ROUTINE FOR THE VECTORIZED GAP COMPUTATION
*
* The standardized gap between White and Black students in a cell is Ho's
* (2009) V statistic, the difference in means divided by the pooled standard
* deviation. compute_gaps_vec() computes V and its delta-method standard
* error for every cell in one matrix operation, reading the standardized
* means and SDs from the dataset in memory and writing gap_wb and gap_wb_se
* back. gapci (code/ado) applies the same formulas to one pair of groups.
*==============================================================================
capture mata: mata drop compute_gaps_vec()
mata:
mata set matastrict off

void compute_gaps_vec()
{
    real colvector mu_w, mu_b, sd_w, sd_b, se_mw, se_mb, se_sw, se_sb
    real colvector pooled_sd, gap, dV_dmuw, dV_dmub, dV_dsdw, dV_dsdb
    real colvector gap_var, gap_se
    real scalar    idx_gap, idx_se

    st_view(mu_w  = ., ., "mu_white")
    st_view(mu_b  = ., ., "mu_black")
    st_view(sd_w  = ., ., "sd_white")
    st_view(sd_b  = ., ., "sd_black")
    st_view(se_mw = ., ., "mu_white_se")
    st_view(se_mb = ., ., "mu_black_se")
    st_view(se_sw = ., ., "sd_white_se")
    st_view(se_sb = ., ., "sd_black_se")

    pooled_sd = sqrt((sd_w :^ 2 :+ sd_b :^ 2) :/ 2)
    gap       = (mu_w :- mu_b) :/ pooled_sd

    // Delta-method gradients of V with respect to the four estimates
    dV_dmuw =   1 :/ pooled_sd
    dV_dmub =  -1 :/ pooled_sd
    dV_dsdw = -(mu_w :- mu_b) :* sd_w :/ (2 :* pooled_sd :^ 3)
    dV_dsdb = -(mu_w :- mu_b) :* sd_b :/ (2 :* pooled_sd :^ 3)

    gap_var = (dV_dmuw :^ 2) :* (se_mw :^ 2) :+
              (dV_dmub :^ 2) :* (se_mb :^ 2) :+
              (dV_dsdw :^ 2) :* (se_sw :^ 2) :+
              (dV_dsdb :^ 2) :* (se_sb :^ 2)
    gap_se  = sqrt(gap_var)

    idx_gap = st_addvar("double", "gap_wb")
    idx_se  = st_addvar("double", "gap_wb_se")
    st_store(., idx_gap, gap)
    st_store(., idx_se,  gap_se)
}

end
display as result "Mata routine compute_gaps_vec() compiled."

*==============================================================================
* PART 2. HETOP ESTIMATION, ONE FIT PER COUNTY-GRADE CELL
*
* Each fit has three groups (all students, White, Black) and four ordered
* categories. identify(sums) constrains the population-weighted sum of the
* group means and of the log standard deviations to zero, which treats the
* groups symmetrically; hetop then reports the estimates in its standardized
* metric (mean 0 and SD 1 across the cell's population). Because the
* categories were reconstructed from one proficiency rate (step 02), the SD
* estimates are close to 1 by construction; the information in the data is
* the location of each group relative to the proficient cut.
*==============================================================================
use "${derived}/proficiency_counts.dta", clear

egen long cell_id = group(county_fips grade year)
label var cell_id "County-grade-year cell identifier"
sort cell_id subgroup

quietly levelsof cell_id, local(cells)
local n_cells : word count `cells'
local step = max(1, floor(`n_cells' / 20))

tempname pf
postfile `pf' long(cell_id county_fips grade year) byte(subgroup) ///
    long(n_tested) double(pct_proficient) ///
    double(mu_hat sigma_hat mu_hat_se sigma_hat_se ///
           mu_std sigma_std mu_std_se sigma_std_se) ///
    byte(converged) ///
    using "${derived}/hetop_estimates.dta", replace

display as text _n "Fitting HETOP to `n_cells' county-grade cells..."
timer clear 31
timer on 31

local i = 0
local n_failed = 0
local n_incomplete = 0

foreach c of local cells {
    local ++i

    preserve
        quietly keep if cell_id == `c'
        quietly count
        local nrows = r(N)
        local cfips = county_fips[1]
        local gg    = grade[1]
        local yy    = year[1]

        * A cell without all three subgroups cannot be fit with the common
        * design; it is written out with missing estimates so that the count
        * of incomplete cells is visible downstream.
        if `nrows' != 3 {
            forvalues s = 1/3 {
                post `pf' (`c') (`cfips') (`gg') (`yy') (`s') (.) (.) ///
                    (.) (.) (.) (.) (.) (.) (.) (.) (0)
            }
            restore
            local ++n_incomplete
            continue
        }

        capture quietly hetop subgroup n_cat, numcats(4) identify(sums) gaps minsize(20)
        local rc = _rc
        local ok = (`rc' == 0)
        if `ok' local ok = (e(converged) == 1)
        * A fit that returns fewer than three groups (hetop drops groups below
        * its minsize) is treated as a failure rather than read out of order
        if `ok' local ok = (rowsof(e(mstar)) == 3)

        if `ok' {
            matrix _Mstar = e(mstar)
            matrix _Sstar = e(sstar)
            matrix _MseS  = e(mstar_se)
            matrix _SseS  = e(sstar_se)
            matrix _Mraw  = e(mraw)
            matrix _Sraw  = e(sraw)
            matrix _MseR  = e(mraw_se)
            matrix _SseR  = e(sraw_se)

            * hetop orders groups by the numeric value of subgroup (1, 2, 3)
            forvalues s = 1/3 {
                local ns = n_tested[`s']
                local pp = pct_proficient[`s']
                post `pf' (`c') (`cfips') (`gg') (`yy') (`s') (`ns') (`pp') ///
                    (_Mraw[`s', 1])  (_Sraw[`s', 1])  ///
                    (_MseR[`s', 1])  (_SseR[`s', 1])  ///
                    (_Mstar[`s', 1]) (_Sstar[`s', 1]) ///
                    (_MseS[`s', 1])  (_SseS[`s', 1])  ///
                    (1)
            }
        }
        else {
            forvalues s = 1/3 {
                local ns = n_tested[`s']
                local pp = pct_proficient[`s']
                post `pf' (`c') (`cfips') (`gg') (`yy') (`s') (`ns') (`pp') ///
                    (.) (.) (.) (.) (.) (.) (.) (.) (0)
            }
            local ++n_failed
        }
    restore

    if mod(`i', `step') == 0 {
        display as text "  processed " %5.0f `i' " / `n_cells' (" %3.0f 100 * `i' / `n_cells' "%)"
    }
}
postclose `pf'

timer off 31
quietly timer list 31
display as result _n "HETOP estimation finished in " %7.1f r(t31) " seconds (" ///
    %5.2f r(t31) / `n_cells' " per cell)."
display as result "Cells: `n_cells'. Incomplete (a subgroup missing): `n_incomplete'. " ///
    "Failed or not converged: `n_failed'."
record_runtime "03_hetop_fits" `=r(t31)'
record_runtime "03_hetop_cells" `n_cells'

use "${derived}/hetop_estimates.dta", clear
gen int fips = floor(county_fips / 1000)
label_states fips
label define subgrp 1 "All students" 2 "White" 3 "Black", replace
label values subgroup subgrp
label var fips           "State FIPS code"
label var subgroup       "Subgroup (1 all students, 2 White, 3 Black)"
label var n_tested       "Students tested in the cell"
label var pct_proficient "Percent at or above proficient"
label var mu_hat         "HETOP mean, identification metric"
label var sigma_hat      "HETOP SD, identification metric"
label var mu_hat_se      "SE of HETOP mean, identification metric"
label var sigma_hat_se   "SE of HETOP SD, identification metric"
label var mu_std         "HETOP mean, standardized metric"
label var sigma_std      "HETOP SD, standardized metric"
label var mu_std_se      "SE of standardized mean"
label var sigma_std_se   "SE of standardized SD"
label var converged      "Cell converged (1) or not (0)"
compress
save "${derived}/hetop_estimates.dta", replace

*------------------------------------------------------------------------------
* Convergence summary, by state, for the manual
*------------------------------------------------------------------------------
preserve
    quietly keep if subgroup == 1
    gen byte incomplete = missing(n_tested)
    collapse (count) cells = cell_id (sum) converged incomplete, by(fips)
    gen long failed = cells - converged - incomplete
    label var cells      "County-grade cells"
    label var converged  "Converged"
    label var incomplete "Incomplete (a subgroup missing)"
    label var failed     "Failed or not converged"
    list, noobs abbreviate(12)
    export delimited using "${tables}/hetop_convergence.csv", replace nolabel
restore

quietly summarize sigma_std if converged == 1, detail
display as result _n "Standardized SDs across converged cells: median " %6.3f r(p50) ///
    ", min " %6.3f r(min) ", max " %6.3f r(max)

*==============================================================================
* PART 3. WHITE-BLACK GAPS BY CELL
*==============================================================================
use "${derived}/hetop_estimates.dta", clear
keep cell_id county_fips fips grade year subgroup ///
     mu_std sigma_std mu_std_se sigma_std_se n_tested pct_proficient converged

reshape wide mu_std sigma_std mu_std_se sigma_std_se n_tested pct_proficient converged, ///
    i(cell_id county_fips fips grade year) j(subgroup)

rename mu_std2        mu_white
rename mu_std3        mu_black
rename sigma_std2     sd_white
rename sigma_std3     sd_black
rename mu_std_se2     mu_white_se
rename mu_std_se3     mu_black_se
rename sigma_std_se2  sd_white_se
rename sigma_std_se3  sd_black_se
rename n_tested2      n_white
rename n_tested3      n_black
rename pct_proficient2 pct_white
rename pct_proficient3 pct_black
rename converged2     conv_white
rename converged3     conv_black
drop mu_std1 sigma_std1 mu_std_se1 sigma_std_se1 n_tested1 pct_proficient1 converged1

gen byte keep_cell = (conv_white == 1) & (conv_black == 1)
quietly count if !keep_cell
display as text "Cells without converged White and Black estimates (dropped): " r(N)
drop if !keep_cell
drop keep_cell

mata: compute_gaps_vec()
label var gap_wb    "White-Black gap, V statistic (HETOP)"
label var gap_wb_se "SE of V, delta method on HETOP estimates"

*------------------------------------------------------------------------------
* The direct estimator as a check on HETOP
*
* With one proficiency cut per cell, the gap can also be estimated directly
* as the difference between the probits of the two groups' proficiency rates,
* with a standard error from the binomial variance of each rate (delta
* method). V and the direct estimate should agree closely; the two standard
* errors need not, because HETOP's standard errors treat the reconstructed
* categories as observed, while the binomial standard error uses only the
* information the published rate carries. The ratio is reported here and the
* binomial-based intervals accompany the HETOP intervals in the output.
*------------------------------------------------------------------------------
gen double _pw = pct_white / 100
gen double _pb = pct_black / 100
gen double gap_direct = invnormal(_pw) - invnormal(_pb)
gen double gap_direct_se = sqrt( _pw * (1 - _pw) / (n_white * normalden(invnormal(_pw))^2) ///
                               + _pb * (1 - _pb) / (n_black * normalden(invnormal(_pb))^2) )
drop _pw _pb
label var gap_direct    "White-Black gap, difference of probits of proficiency rates"
label var gap_direct_se "SE of the direct gap, binomial delta method"

gen double se_ratio = gap_direct_se / gap_wb_se
label var se_ratio "Binomial SE divided by HETOP SE"

quietly correlate gap_wb gap_direct
local r_hd = r(rho)
gen double _absdiff = abs(gap_wb - gap_direct)
quietly summarize _absdiff, detail
local mad_hd = r(p50)
local maxad_hd = r(max)
quietly summarize se_ratio, detail
local ratio_p50 = r(p50)
local ratio_p10 = r(p10)
local ratio_p90 = r(p90)
drop _absdiff

display as result _n "HETOP V against the direct probit difference, " _N " cells:"
display as result "   correlation " %6.4f `r_hd' ", median absolute difference " %7.4f `mad_hd' ///
    ", largest " %7.4f `maxad_hd'
display as result "   binomial SE / HETOP SE: median " %5.2f `ratio_p50' ///
    " (10th to 90th percentile " %5.2f `ratio_p10' " to " %5.2f `ratio_p90' ")"

tempname fh
file open `fh' using "${tables}/se_comparison.csv", write replace text
file write `fh' "statistic,value" _n
file write `fh' "cells,`=_N'" _n
file write `fh' "correlation_v_direct,`r_hd'" _n
file write `fh' "median_abs_diff,`mad_hd'" _n
file write `fh' "max_abs_diff,`maxad_hd'" _n
file write `fh' "se_ratio_p50,`ratio_p50'" _n
file write `fh' "se_ratio_p10,`ratio_p10'" _n
file write `fh' "se_ratio_p90,`ratio_p90'" _n
file close `fh'

compress
* reshape wide leaves its bookkeeping in the dataset characteristics; it is
* not needed again and would travel with the file
reshape clear
save "${derived}/gaps_cell_level.dta", replace
display as result _n "Gap computation complete: " _N " county-grade gaps."

*==============================================================================
* PART 4. POOLING ACROSS GRADES
*
* The grade-level gaps of a county are combined into one estimate with a
* random-intercept model under inverse-variance weights, the random-effects
* meta-analytic setup of Hedges and Vevea (1998) that SEDA adapts to pool
* unit estimates (Fahle et al. 2026, SEDA technical documentation). Stata's
* mixed does not take analytic weights, so the model
*     gap_cg = alpha + beta grade_g + u_c + e_cg,   Var(e_cg) = sigma^2 / w_cg
* is multiplied through by the square root of the weight. Every term must be
* scaled, the county intercept included: on the transformed scale the county
* effect is a random coefficient on sqrt(w) with no separate intercept. The
* county's pooled gap is its empirical Bayes intercept plus the fixed part
* evaluated at the middle grade of GRADES.
*==============================================================================
use "${derived}/gaps_cell_level.dta", clear
drop if gap_wb_se <= 0 | missing(gap_wb_se)

gen double prec_weight = 1 / (gap_wb_se ^ 2)
label var prec_weight "Inverse-variance weight (HETOP SE)"
gen double prec_weight_direct = 1 / (gap_direct_se ^ 2)
label var prec_weight_direct "Inverse-variance weight (binomial SE)"

gen double _sw      = sqrt(prec_weight)
gen double gap_wb_w = gap_wb * _sw
gen double grade_w  = grade  * _sw
gen double cons_w   = _sw

* Reference grade for the pooled estimate: the middle element of GRADES
local n_grades_scope : word count ${GRADES}
local gref : word `=ceil(`n_grades_scope' / 2)' of ${GRADES}

* Plain (unweighted) per-county means of the numbers tested, for description
bysort county_fips: egen double n_white_mean = mean(n_white)
bysort county_fips: egen double n_black_mean = mean(n_black)
gen byte one = 1

display as text _n "Precision-weighted random-intercept model (all cells from one school year, so grade is the only within-county covariate)"
mixed gap_wb_w cons_w grade_w, noconstant || county_fips: cons_w, noconstant reml nolog

scalar _alpha = _b[cons_w]
scalar _beta  = _b[grade_w]
* The residual variance should be 1 if the cell-level standard errors were
* exactly right; a larger value means the gaps vary across grades more than
* those standard errors imply.
scalar _resid_var = exp(2 * _b[lnsig_e:_cons])
display as result "Residual variance of the weighted model: " %6.3f _resid_var

* Variance of the county effects (the random coefficient on sqrt(w) is the
* county intercept on the gap scale)
scalar _var_cons = exp(2 * _b[lns1_1_1:_cons])
predict double _cty_ranef, reffects
drop _sw gap_wb_w grade_w cons_w

display as result "Fixed part: intercept " %7.4f _alpha ", grade slope " %7.4f _beta ///
    "; county variance " %7.4f _var_cons

* Summary of the pooling model for the manual
tempname fh
file open `fh' using "${tables}/pooling_summary.csv", write replace text
file write `fh' "statistic,value" _n
file write `fh' "cells,`=e(N)'" _n
file write `fh' "counties,`=el(e(N_g), 1, 1)'" _n
file write `fh' "intercept,`=_alpha'" _n
file write `fh' "grade_slope,`=_beta'" _n
file write `fh' "reference_grade,`gref'" _n
file write `fh' "grand_gap_grade6,`=_alpha + `gref' * _beta'" _n
file write `fh' "grade_slope_se,`=_se[grade_w]'" _n
file write `fh' "county_variance,`=_var_cons'" _n
file write `fh' "residual_variance,`=_resid_var'" _n
file close `fh'

* The total precision of a county is the plain sum of its cell weights. With
* a weight in effect, collapse's (sum) would return the weighted sum, that is
* the sum of squared precisions, and (count) the sum of weights; (rawsum)
* ignores the weight. The county effect and the plain means are constant
* within county and are carried with (firstnm).
collapse (firstnm) _cty_ranef n_white_mean n_black_mean fips  ///
         (mean) gap_wb_raw         = gap_wb                ///
         (rawsum) prec_county      = prec_weight           ///
         (rawsum) prec_county_direct = prec_weight_direct  ///
         (rawsum) n_grades         = one                   ///
         [pweight = prec_weight],                          ///
         by(county_fips)

gen double gap_wb_pooled    = _cty_ranef + _alpha + _beta * `gref'
gen double gap_wb_pooled_se = 1 / sqrt(prec_county)
gen double gap_wb_pooled_se_direct = 1 / sqrt(prec_county_direct)
drop _cty_ranef
recast byte n_grades

label var gap_wb_pooled           "Pooled White-Black gap (empirical Bayes, grade `gref' reference)"
label var gap_wb_pooled_se        "SE of pooled gap from total HETOP precision"
label var gap_wb_pooled_se_direct "SE of pooled gap from total binomial precision"
label var gap_wb_raw              "Precision-weighted mean of the cell gaps"
label var prec_county             "Total precision (HETOP), sum of cell weights"
label var prec_county_direct      "Total precision (binomial), sum of cell weights"
label var n_white_mean            "White students tested per grade, mean over grades"
label var n_black_mean            "Black students tested per grade, mean over grades"
label var n_grades                "Grades with a gap estimate"
label var fips                    "State FIPS code"
label_states fips

merge 1:1 county_fips using "${derived}/county_covariates.dta", keep(match) nogen
reshape clear
save "${derived}/gaps_county_level.dta", replace
display as result _n "Pooled to " _N " county-level gap estimates."
tabulate fips

*==============================================================================
* PART 5. REGRESSION LADDER
*
* Four nested specifications, each adding one county characteristic: child
* poverty; the log number of districts; the Black share of enrollment; and
* the between-district dispersion of Black enrollment share. Counties are
* weighted by the precision of their pooled gap, and standard errors are
* robust to heteroskedasticity. The ladder describes associations; nothing
* here identifies a causal effect.
*==============================================================================
use "${derived}/gaps_county_level.dta", clear

label var gap_wb_pooled           "Pooled White-Black gap (V)"
label var gap_wb_pooled_se        "SE of pooled gap"
label var poverty_rate            "Child poverty rate (SAIPE, ages 5 to 17)"
label var district_fragmentation  "Log number of districts"
label var share_black             "Black share of enrollment"
label var seg_bw_index            "Between-district dispersion of Black share"
label var n_white_mean            "White students tested per grade (mean)"
label var n_black_mean            "Black students tested per grade (mean)"

eststo clear
eststo t1: estpost summarize gap_wb_pooled gap_wb_pooled_se poverty_rate ///
    district_fragmentation share_black seg_bw_index n_white_mean n_black_mean

esttab t1 using "${tables}/table1_descriptives.html", replace                       ///
    cells("mean(fmt(3)) sd(fmt(3)) min(fmt(3)) max(fmt(3))")                         ///
    label nonumber nomtitle                                                          ///
    title("Table 1. County-level sample") addnotes("N = `=_N' counties.")
esttab t1 using "${tables}/table1_descriptives.tex", replace booktabs                 ///
    cells("mean(fmt(3)) sd(fmt(3)) min(fmt(3)) max(fmt(3))")                         ///
    label nonumber nomtitle title("County-level sample")

eststo clear
eststo m1: regress gap_wb_pooled poverty_rate [pweight = prec_county], robust
eststo m2: regress gap_wb_pooled poverty_rate district_fragmentation [pweight = prec_county], robust
eststo m3: regress gap_wb_pooled poverty_rate district_fragmentation share_black ///
    [pweight = prec_county], robust
eststo m4: regress gap_wb_pooled poverty_rate district_fragmentation share_black seg_bw_index ///
    [pweight = prec_county], robust

quietly estimates restore m4
display as text _n "Nested test, model 3 against model 4: does between-district dispersion add to poverty, fragmentation and composition?"
test seg_bw_index
scalar F_seg = r(F)
scalar p_seg = r(p)
display as result "  F(1, " r(df_r) ") = " %6.3f F_seg ", p = " %6.4f p_seg
file open `fh' using "${tables}/pooling_summary.csv", write append text
file write `fh' "nested_F,`=F_seg'" _n
file write `fh' "nested_F_df,`=r(df_r)'" _n
file write `fh' "nested_p,`=p_seg'" _n
file write `fh' "ladder_counties,`=e(N)'" _n
file close `fh'

esttab m1 m2 m3 m4 using "${tables}/table2_gap_regression.html", replace             ///
    label se star(* 0.10 ** 0.05 *** 0.01) b(3) se(3) nonumbers nonotes               ///
    stats(N r2_a, fmt(0 3) labels("Counties" "Adjusted R-squared"))                  ///
    title("Table 2. Regression of the pooled White-Black gap on county characteristics") ///
    mtitles("(1)" "(2)" "(3)" "(4)")                                                 ///
    addnotes("Weighted by the precision of the pooled gap. Robust standard errors in parentheses.")
esttab m1 m2 m3 m4 using "${tables}/table2_gap_regression.tex", replace booktabs     ///
    label se star(* 0.10 ** 0.05 *** 0.01) b(3) se(3) nonumbers nonotes               ///
    stats(N r2_a, fmt(0 3) labels("Counties" "Adjusted R-squared"))                  ///
    title("Regression of the pooled White-Black gap on county characteristics")      ///
    mtitles("(1)" "(2)" "(3)" "(4)")
estimates save "${derived}/ladder_estimates.ster", replace

* Coefficients of the ladder in a flat file, for the documents
file open `fh' using "${tables}/ladder_coefficients.csv", write replace text
file write `fh' "model,variable,b,se,r2_a,r2,n" _n
forvalues k = 1/4 {
    quietly estimates restore m`k'
    foreach v in poverty_rate district_fragmentation share_black seg_bw_index {
        capture local b = _b[`v']
        if _rc continue
        file write `fh' "`k',`v',`=_b[`v']',`=_se[`v']',`=e(r2_a)',`=e(r2)',`=e(N)'" _n
    }
}
file close `fh'

*==============================================================================
* PART 6. gapci: demonstration and check against the vectorized routine
*
* gapci returns V and its delta-method interval for one pair of groups. It is
* run on the first cell for illustration, then on every cell to confirm that
* it reproduces compute_gaps_vec() to numerical precision.
*==============================================================================
use "${derived}/hetop_estimates.dta", clear
quietly keep if converged == 1
sort cell_id subgroup
local c1 = cell_id[1]
quietly keep if cell_id == `c1'
local mu_w  = mu_std[2]
local sd_w  = sigma_std[2]
local semw  = mu_std_se[2]
local sesw  = sigma_std_se[2]
local mu_b  = mu_std[3]
local sd_b  = sigma_std[3]
local semb  = mu_std_se[3]
local sesb  = sigma_std_se[3]
display as result _n "gapci on county " county_fips[1] ", grade " grade[1] ":"
display as text "gapci, mean1(" %6.4f `mu_w' ") se1(" %6.4f `semw' ") sd1(" %6.4f `sd_w' ///
    ") sdse1(" %6.4f `sesw' ") mean2(" %7.4f `mu_b' ") se2(" %6.4f `semb' ") sd2(" ///
    %6.4f `sd_b' ") sdse2(" %6.4f `sesb' ") level(95)"
gapci, mean1(`mu_w') se1(`semw') sd1(`sd_w') sdse1(`sesw') ///
       mean2(`mu_b') se2(`semb') sd2(`sd_b') sdse2(`sesb') level(95)

use "${derived}/gaps_cell_level.dta", clear
gen double gap_check = .
gen double se_check  = .
quietly forvalues i = 1/`=_N' {
    gapci, mean1(`=mu_white[`i']') se1(`=mu_white_se[`i']') sd1(`=sd_white[`i']') sdse1(`=sd_white_se[`i']') ///
           mean2(`=mu_black[`i']') se2(`=mu_black_se[`i']') sd2(`=sd_black[`i']') sdse2(`=sd_black_se[`i']') ///
           noheader
    replace gap_check = r(gap)    in `i'
    replace se_check  = r(gap_se) in `i'
}
gen double _d1 = abs(gap_check - gap_wb)
gen double _d2 = abs(se_check - gap_wb_se)
quietly summarize _d1
local maxd1 = r(max)
quietly summarize _d2
local maxd2 = r(max)
display as result _n "gapci against compute_gaps_vec() on " _N " cells: largest difference in V " ///
    %10.2e `maxd1' ", in SE " %10.2e `maxd2'
if `maxd1' > 1e-9 | `maxd2' > 1e-9 {
    display as error "gapci and compute_gaps_vec() disagree beyond numerical precision."
    exit 9
}

display as result _n "Estimation complete."
log close step03
