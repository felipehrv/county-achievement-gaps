/*==============================================================================
    02_build_master.do
    Builds the two county-level analytic files: proficiency counts by county,
    grade and subgroup, and county covariates from CCD and SAIPE.

    Inputs       : data/raw/edfacts_district_race.dta, data/raw/ccd_directory.dta,
                   data/raw/ccd_enrollment_race.dta, data/raw/saipe_district.dta;
                   globals set by run_all.do
    Outputs      : data/derived/proficiency_counts.dta
                   data/derived/county_covariates.dta
                   output/tables/exclusions_district_cells.csv (and .dta)
                   output/tables/covariate_imputation.csv
                   output/logs/02_build_master.log
    Dependencies : Stata 17 or later; no community packages
    Author       : Felipe Hernán Rodríguez Villalta
    Year         : 2026
==============================================================================*/

if "${root}" == "" {
    display as error "Run this script through run_all.do, which sets the scope and the paths."
    exit 198
}

capture log close step02
log using "${logs}/02_build_master.log", replace text name(step02)

*==============================================================================
* PART A. PROFICIENCY COUNTS
*==============================================================================

*------------------------------------------------------------------------------
* A1. Subgroups and special codes
*
* The analysis compares White and Black students; the all-students row is kept
* because HETOP uses it as a third group when it standardizes each cell.
*
* The portal codes missing or not reported values as -1, not applicable as
* -2 and values suppressed by the Department of Education as -3. Suppression
* protects small groups of students. These codes are recoded to Stata's
* extended missing values so that every excluded row carries its reason, and
* nothing is ever imputed for a suppressed cell.
*------------------------------------------------------------------------------
use "${raw}/edfacts_district_race.dta", clear

capture confirm numeric variable race
if !_rc {
    decode race, generate(race_str)
    drop race
    rename race_str race
}
keep if inlist(race, "Total", "White", "Black")

gen byte subgroup = cond(race == "Total", 1, cond(race == "White", 2, 3))
label define subgrp 1 "All students" 2 "White" 3 "Black"
label values subgroup subgrp
drop race

rename math_test_num_valid      n_tested
rename math_test_pct_prof_midpt pct_proficient
rename math_test_pct_prof_low   pct_low
rename math_test_pct_prof_high  pct_high
rename grade_edfacts            grade

foreach v in n_tested pct_proficient pct_low pct_high {
    capture confirm string variable `v'
    if !_rc destring `v', replace force
    quietly replace `v' = .a if `v' == -1
    quietly replace `v' = .b if `v' == -2
    quietly replace `v' = .c if `v' == -3
}

*------------------------------------------------------------------------------
* A2. Exclusions at the district level, with their reasons
*
* A district-grade-subgroup row enters the county aggregate only if the number
* tested and the proficiency rate are both reported and at least MIN_CELL_N
* students were tested. Below that size EDFacts publishes the rate in ranges
* of ten points or more, so the midpoint carries little information, and the
* Black-subgroup HETOP estimates become unstable. The table written here is
* the source for the suppression and exclusion accounting in the manual.
*------------------------------------------------------------------------------
gen byte excl_reason = 0
replace excl_reason = 1 if n_tested == .c | pct_proficient == .c
replace excl_reason = 2 if excl_reason == 0 & (missing(n_tested) | missing(pct_proficient))
replace excl_reason = 3 if excl_reason == 0 & n_tested < ${MIN_CELL_N}
label define exclr 0 "Kept" 1 "Suppressed by EDFacts" ///
    2 "Not reported or not applicable" 3 "Fewer than ${MIN_CELL_N} tested", replace
label values excl_reason exclr

display as result _n "District-grade-subgroup rows by subgroup and exclusion reason"
tabulate subgroup excl_reason

preserve
    gen double students = n_tested if n_tested < .
    gen byte one = 1
    collapse (sum) rows = one (sum) students, by(fips subgroup excl_reason)
    * A state-subgroup-reason total built from one or two district rows would
    * repeat a published small count on its own; it is withheld.
    replace students = . if rows < 3
    label var rows     "District-grade-subgroup rows"
    label var students "Students tested in those rows (where reported; withheld when fewer than 3 rows)"
    save "${tables}/exclusions_district_cells.dta", replace
    export delimited using "${tables}/exclusions_district_cells.csv", replace
restore

keep if excl_reason == 0
drop excl_reason
display as result "Rows kept for aggregation: " _N

tempfile edfacts_filtered
save `edfacts_filtered'

*------------------------------------------------------------------------------
* A3. Crosswalk from district to county through the CCD directory
*
* Every merge in this script uses the numeric value of the district id. The
* portal zero-pads the seven-digit leaid in some files and not in others
* (SAIPE, in particular, arrives without the leading zero), and a string merge
* would silently lose every district in a state whose FIPS code starts with 0.
*------------------------------------------------------------------------------
use "${raw}/ccd_directory.dta", clear

capture confirm string variable leaid
if !_rc gen long leaid_n = real(leaid)
else    gen long leaid_n = leaid

capture confirm string variable county_code
if !_rc destring county_code, replace

capture confirm string variable fips
if !_rc destring fips, replace

* The portal's special codes (-1, -2, -3) are recoded to missing here too
foreach v in county_code enrollment {
    quietly replace `v' = . if inlist(`v', -1, -2, -3)
}

duplicates drop leaid_n, force

* A few directory records (charter schools, mostly) carry a county code in
* another state. The county is the unit of analysis and a county outside the
* study states has no covariates here, so those records are set aside.
gen int county_state = floor(county_code / 1000)
quietly count if !missing(county_code) & county_state != fips
display as text "Districts whose county lies in another state (dropped): " r(N)
drop if !missing(county_code) & county_state != fips
drop county_state

keep leaid_n county_code enrollment lea_name
tempfile xw
save `xw'

use `edfacts_filtered', clear
capture confirm string variable leaid
if !_rc gen long leaid_n = real(leaid)
else    gen long leaid_n = leaid

merge m:1 leaid_n using `xw', keep(master match) nogen
quietly count if missing(county_code)
display as text "Rows without a county in the CCD directory (dropped): " r(N)
drop if missing(county_code)
rename county_code county_fips

*------------------------------------------------------------------------------
* A4. From districts to county-grade-subgroup cells
*
* The number tested is the plain sum over districts. The county proficiency
* rate is the mean of district rates weighted by the number tested, which
* makes it the rate among the county's tested students. (rawsum ignores the
* weight; a weighted sum would scale the count by the number of districts.)
*------------------------------------------------------------------------------
quietly collapse (rawsum) n_tested (mean) pct_proficient [aweight = n_tested], ///
    by(county_fips grade subgroup)

gen int year = ${EDF_YEAR}
gen int fips = floor(county_fips / 1000)

*------------------------------------------------------------------------------
* A5. County eligibility
*
* A county enters the sample only when its Black cell has at least MIN_CELL_N
* tested students in every grade. The rule is applied to the Black subgroup
* because it is the smaller of the two compared groups in most counties, and
* a county with one unstable grade would pool an unstable estimate.
*------------------------------------------------------------------------------
bysort county_fips grade (subgroup): egen long n_black = ///
    max(cond(subgroup == 3, n_tested, 0))
* Every grade of GRADES must be present for the county with a Black cell of
* at least MIN_CELL_N; a county with no kept cell in some grade fails too.
bysort county_fips grade: gen byte _g1 = (_n == 1)
bysort county_fips: egen byte _n_grades_present = total(_g1)
bysort county_fips: egen byte _min_ok = min(cond(n_black >= ${MIN_CELL_N}, 1, 0))
gen byte all_grades_ok = (_min_ok == 1) & (_n_grades_present == `: word count ${GRADES}')
drop _g1 _n_grades_present _min_ok

preserve
    quietly keep if subgroup == 3
    quietly bysort county_fips: keep if _n == 1
    display as result _n "Counties with any kept Black cell, by state, and counties meeting the rule"
    tabulate fips all_grades_ok
    gen byte one = 1
    collapse (sum) counties_with_black_cells = one counties_eligible = all_grades_ok, by(fips)
    export delimited using "${tables}/county_eligibility.csv", replace
restore

drop if all_grades_ok == 0
drop n_black all_grades_ok

* Cells where a subgroup is missing in some grade (usually White students in
* majority-Black counties) stay in the file; step 03 flags the incomplete
* county-grade cells and the gap is not computed for them.
quietly bysort county_fips grade: gen byte cell_complete = (_N == 3)
label var cell_complete "All three subgroups present in the county-grade cell"

*------------------------------------------------------------------------------
* A6. Four ordered categories from one proficiency rate
*
* EDFacts public files report a single cut: the share of students at or above
* the state's proficient standard. HETOP needs counts in ordered categories,
* so each cell's counts are reconstructed under two assumptions: achievement
* in the cell is normal with unit variance, and the state's category cut
* scores sit at -1, 0 and 1 in that metric, with the proficient cut at 0.
* The reconstruction therefore fixes the within-cell standard deviation; what
* the data identify is the location of each cell's distribution relative to
* the proficient cut, and hence the difference in location between groups.
* Step 03 reports how this bears on the standard errors.
*------------------------------------------------------------------------------
* A rate of exactly 0 or 100 has no finite probit; such cells are bounded
* at 0.5 and 99.5 percent and counted (none occur in the default scope, where
* small cells carry range midpoints).
gen double _p = min(max(pct_proficient / 100, 0.005), 0.995)
quietly count if _p != pct_proficient / 100
display as text "Cells with a proficiency rate bounded away from 0 or 100 percent: " r(N)
gen double _mu_imp = -invnormal(1 - _p)
drop _p
gen double p_cat1 = normal(-1 - _mu_imp)
gen double p_cat2 = normal( 0 - _mu_imp) - p_cat1
gen double p_cat3 = normal( 1 - _mu_imp) - p_cat1 - p_cat2
gen double p_cat4 = 1 - p_cat1 - p_cat2 - p_cat3
foreach v in p_cat1 p_cat2 p_cat3 p_cat4 {
    replace `v' = max(0, min(1, `v'))
}

gen long n_cat1 = round(n_tested * p_cat1)
gen long n_cat2 = round(n_tested * p_cat2)
gen long n_cat3 = round(n_tested * p_cat3)
gen long n_cat4 = n_tested - n_cat1 - n_cat2 - n_cat3
drop _mu_imp p_cat*
assert n_cat1 >= 0 & n_cat2 >= 0 & n_cat3 >= 0 & n_cat4 >= 0

label var county_fips    "County FIPS code"
label var fips           "State FIPS code"
label var grade          "Test grade"
label var year           "School year (portal code: year the school year begins)"
label var subgroup       "Subgroup (1 all students, 2 White, 3 Black)"
label var n_tested       "Students tested in the cell"
label var pct_proficient "Percent at or above proficient (tested-weighted mean of district midpoints)"
label var n_cat1         "Count: below basic (reconstructed)"
label var n_cat2         "Count: basic (reconstructed)"
label var n_cat3         "Count: proficient (reconstructed)"
label var n_cat4         "Count: advanced (reconstructed)"

order county_fips fips grade year subgroup n_tested pct_proficient n_cat1 n_cat2 n_cat3 n_cat4 cell_complete
compress
save "${derived}/proficiency_counts.dta", replace

quietly count
local n_rows = r(N)
quietly levelsof county_fips, local(clist)
local n_counties : word count `clist'
display as result _n "Proficiency counts: `n_rows' county-grade-subgroup cells in `n_counties' counties."
quietly bysort county_fips: gen byte _first = _n == 1
tabulate fips if _first
drop _first

*==============================================================================
* PART B. COUNTY COVARIATES
*==============================================================================

*------------------------------------------------------------------------------
* B1. Child poverty from SAIPE, aggregated to counties
*
* SAIPE estimates the share of children aged 5 to 17 in poverty for every
* school district. The county rate is the mean of district rates weighted by
* the district's population of that age.
*------------------------------------------------------------------------------
use "${raw}/saipe_district.dta", clear
capture confirm string variable leaid
if !_rc gen long leaid_n = real(leaid)
else    gen long leaid_n = leaid

merge 1:1 leaid_n using `xw', keep(match) nogen
display as text "SAIPE districts matched to the CCD directory: " _N
foreach v in est_population_5_17 est_population_5_17_poverty_pct {
    quietly replace `v' = . if inlist(`v', -1, -2, -3)
}
drop if missing(county_code) | missing(est_population_5_17_poverty_pct) | missing(est_population_5_17)

rename county_code county_fips
rename est_population_5_17_poverty_pct poverty_rate_district
rename est_population_5_17 pop_5_17

quietly collapse (mean) poverty_rate = poverty_rate_district [aweight = pop_5_17], ///
    by(county_fips)
tempfile saipe_county
save `saipe_county'

*------------------------------------------------------------------------------
* B2. District Black share from CCD enrollment by race
*------------------------------------------------------------------------------
use "${raw}/ccd_enrollment_race.dta", clear
capture confirm string variable leaid
if !_rc gen long leaid_n = real(leaid)
else    gen long leaid_n = leaid

capture confirm numeric variable race
if !_rc {
    decode race, generate(race_str)
    drop race
    rename race_str race
}
keep if inlist(race, "Total", "Black")
keep leaid_n race enrollment
quietly replace enrollment = . if inlist(enrollment, -1, -2, -3)
quietly reshape wide enrollment, i(leaid_n) j(race) string
rename enrollmentTotal dist_total
rename enrollmentBlack dist_black
replace dist_black = 0 if missing(dist_black)
drop if missing(dist_total) | dist_total == 0
gen double dist_black_share = dist_black / dist_total
tempfile enr_district
save `enr_district'

*------------------------------------------------------------------------------
* B3. Composition, between-district dispersion and fragmentation
*
* share_black is the enrollment-weighted mean of district Black shares, which
* equals the county's Black share of enrollment. seg_bw_index is the
* enrollment-weighted standard deviation of district Black shares within the
* county, normalized to lie between 0 and 1. It measures how unevenly Black
* students are distributed across the districts of a county; it is zero by
* construction in counties with a single district, and it does not capture
* sorting between schools inside a district. district_fragmentation is the
* log of the number of districts, a summary of how divided school provision
* is within the county. The composition and dispersion measures use the
* districts with a Black share; the district count uses every district.
*------------------------------------------------------------------------------
use `xw', clear
drop if missing(county_code) | missing(enrollment) | enrollment == 0
rename county_code county_fips
merge m:1 leaid_n using `enr_district', keep(master match) nogen

bysort county_fips: gen long n_districts = _N
gen double district_fragmentation = ln(n_districts)

gen double _w_blkshare = dist_black_share * enrollment
bysort county_fips: egen double _w_blkshare_sum   = total(_w_blkshare)
bysort county_fips: egen double _enr_sum_for_mean = total(enrollment) if !missing(dist_black_share)
bysort county_fips: egen double _enr_fill = max(_enr_sum_for_mean)
replace _enr_sum_for_mean = _enr_fill
drop _enr_fill
gen double county_black_share = _w_blkshare_sum / _enr_sum_for_mean

gen double _sq_dev = ((dist_black_share - county_black_share)^2) * enrollment
bysort county_fips: egen double _sq_sum = total(_sq_dev)
gen double variance_bw = _sq_sum / _enr_sum_for_mean
gen double seg_bw_index = sqrt(variance_bw) / ///
    (sqrt(variance_bw) + sqrt(county_black_share * (1 - county_black_share) + 0.001))

quietly collapse (firstnm) county_black_share seg_bw_index district_fragmentation n_districts, ///
    by(county_fips)
rename county_black_share share_black
tempfile seg_county
save `seg_county'

*------------------------------------------------------------------------------
* B4. Assemble, impute what is still missing, and restrict to sample counties
*
* A covariate missing for a county is filled with the sample mean so that the
* regression sample equals the gap sample. The number of counties imputed is
* counted and written out; with the three sources merged on the numeric
* district id, the count is expected to be zero or close to it.
*------------------------------------------------------------------------------
use `saipe_county', clear
merge 1:1 county_fips using `seg_county', keep(master match using) nogen

preserve
    use "${derived}/proficiency_counts.dta", clear
    keep county_fips
    duplicates drop
    tempfile prof_counties
    save `prof_counties'
restore
merge 1:1 county_fips using `prof_counties', keep(match) nogen

tempname fh
file open `fh' using "${tables}/covariate_imputation.csv", write replace text
file write `fh' "variable,counties_imputed,sample_mean_used" _n
foreach v in poverty_rate share_black seg_bw_index district_fragmentation {
    quietly count if missing(`v')
    local n_imp = r(N)
    quietly summarize `v'
    if !missing(r(mean)) {
        local mn = r(mean)
        quietly replace `v' = `mn' if missing(`v')
        file write `fh' "`v',`n_imp',`mn'" _n
    }
    else {
        display as text "  Warning: `v' is missing for every county; set to 0."
        quietly replace `v' = 0 if missing(`v')
        file write `fh' "`v',`n_imp',0" _n
    }
    display as text "  `v': `n_imp' counties imputed with the sample mean"
}
file close `fh'

gen int fips = floor(county_fips / 1000)
label var county_fips            "County FIPS code"
label var fips                   "State FIPS code"
label var poverty_rate           "SAIPE child poverty rate, ages 5 to 17 (share)"
label var share_black            "Black share of K-12 enrollment"
label var seg_bw_index           "Between-district dispersion of Black enrollment share (0 to 1)"
label var district_fragmentation "Log number of districts in the county"
label var n_districts            "Number of districts in the county"

keep county_fips fips poverty_rate share_black seg_bw_index district_fragmentation n_districts
order county_fips fips
* reshape wide leaves its bookkeeping in the dataset characteristics, which
* would travel with the file; it is not needed again
reshape clear
compress
save "${derived}/county_covariates.dta", replace

display as result _n "County covariates: " _N " counties."
summarize poverty_rate share_black seg_bw_index district_fragmentation n_districts

display as result _n "Build complete: data/derived/proficiency_counts.dta and data/derived/county_covariates.dta"

log close step02
