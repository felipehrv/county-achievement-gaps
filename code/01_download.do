/*==============================================================================
    01_download.do
    Downloads the district-level inputs for the study scope from the Urban
    Institute Education Data Portal and saves the variables the pipeline uses,
    with their values unchanged, in data/raw.

    Inputs       : globals STATES, EDF_YEAR, GRADES and the paths set by
                   run_all.do
    Outputs      : data/raw/edfacts_district_race.dta
                   data/raw/ccd_directory.dta
                   data/raw/ccd_enrollment_race.dta
                   data/raw/saipe_district.dta
                   output/logs/01_download.log
    Dependencies : educationdata (SSC) and its dependency libjson (SSC);
                   an internet connection
    Author       : Felipe Hernán Rodríguez Villalta
    Year         : 2026
==============================================================================*/

if "${root}" == "" {
    display as error "Run this script through run_all.do, which sets the scope and the paths."
    exit 198
}

capture log close step01
log using "${logs}/01_download.log", replace text name(step01)

*------------------------------------------------------------------------------
* Why these four sources
*
* EDFacts gives the outcome: for every district, grade and subgroup, the
* number of students tested in mathematics and the share who scored at or
* above the state's proficient standard. The portal reports that share as a
* midpoint of the range EDFacts publishes; the range is wider for smaller
* groups, which is why small cells are dropped in step 02.
*
* The CCD directory assigns every district to a county, the unit of analysis.
* CCD enrollment by race gives the Black share of enrollment for each
* district, from which step 02 builds the county composition and the
* between-district dispersion measure. SAIPE gives the child poverty rate of
* each district, aggregated to counties in step 02.
*
* The portal republishes the federal files without authentication and codes
* missing, not applicable and suppressed values as -1, -2 and -3. These codes
* are kept as they arrive here; step 02 recodes them to missing in every
* source and, for EDFacts, counts them so that the suppression applied by the
* Department of Education can be documented.
*------------------------------------------------------------------------------

display as result _n "Downloading from the Urban Institute Education Data Portal"
display as result "   States: ${STATES}   Portal year: ${EDF_YEAR}   Grades: ${GRADES}"

*------------------------------------------------------------------------------
* Raw files are reused (REUSE_RAW 1) only if they were downloaded for the
* same scope. The scope stamp written at the end of this script records the
* states, year and grades of the files in data/raw.
*------------------------------------------------------------------------------
local reuse = ${REUSE_RAW}
if `reuse' == 1 {
    local stamp_ok 0
    capture confirm file "${raw}/scope_stamp.txt"
    if !_rc {
        tempname sf
        file open `sf' using "${raw}/scope_stamp.txt", read text
        file read `sf' stamp
        file close `sf'
        if `"`stamp'"' == "STATES=${STATES}|YEAR=${EDF_YEAR}|GRADES=${GRADES}" local stamp_ok 1
    }
    if !`stamp_ok' {
        display as text "  Files in data/raw were downloaded for another scope or have no scope stamp; downloading again."
        local reuse 0
    }
}

* Each endpoint is downloaded once per state (and per grade for EDFacts), the
* pieces are appended, and the result is saved as it arrives. A call that
* fails is retried twice after a pause, because the portal occasionally
* refuses a connection; if it still fails, the pipeline stops instead of
* continuing with an incomplete file.
capture program drop fetch_or_stop
program define fetch_or_stop
    args endpoint subopts
    local rc 1
    forvalues attempt = 1/3 {
        capture noisily educationdata using "`endpoint'", sub(`subopts') clear
        local rc = _rc
        if `rc' == 0 continue, break
        display as text "  attempt `attempt' failed (rc = `rc'); waiting 10 seconds before retrying"
        sleep 10000
    }
    if `rc' {
        display as error "Download failed for `endpoint' (`subopts') after 3 attempts, rc = `rc'"
        display as error "Check the connection and the portal status, then run again."
        exit 498
    }
end

*------------------------------------------------------------------------------
* 1A. EDFacts: mathematics proficiency by race, district level
*------------------------------------------------------------------------------
timer clear 11
timer on 11

capture confirm file "${raw}/edfacts_district_race.dta"
if _rc | `reuse' != 1 {
    tempfile acc
    local first 1
    foreach g in $GRADES {
        foreach st in $STATES {
            display as text _n "  EDFacts: grade `g', state FIPS `st'"
            fetch_or_stop "district edfacts assessments race" ///
                "year=${EDF_YEAR} grade_edfacts=`g' fips=`st'"
            local keepvars leaid year fips grade_edfacts race                     ///
                           math_test_num_valid math_test_pct_prof_midpt          ///
                           math_test_pct_prof_low math_test_pct_prof_high
            capture confirm variable leaid_num
            if !_rc local keepvars `keepvars' leaid_num
            quietly keep `keepvars'
            if `first' {
                quietly save `acc', replace
                local first 0
            }
            else {
                append using `acc'
                quietly save `acc', replace
            }
        }
    }
    use `acc', clear
    compress
    save "${raw}/edfacts_district_race.dta", replace
}
else {
    display as text "  Reusing data/raw/edfacts_district_race.dta"
    use "${raw}/edfacts_district_race.dta", clear
}

timer off 11
quietly timer list 11
display as result _n "EDFacts rows downloaded: " _N " (district x grade x race) in " ///
    %6.1f r(t11) " seconds"
record_runtime "01_edfacts" `=r(t11)'
tabulate fips grade_edfacts

*------------------------------------------------------------------------------
* 1B. CCD district directory: county code and total enrollment
*------------------------------------------------------------------------------
timer clear 12
timer on 12

capture confirm file "${raw}/ccd_directory.dta"
if _rc | `reuse' != 1 {
    tempfile acc
    local first 1
    foreach st in $STATES {
        display as text _n "  CCD directory: state FIPS `st'"
        fetch_or_stop "district ccd directory" "year=${EDF_YEAR} fips=`st'"
        local keepvars leaid year fips lea_name county_code enrollment
        capture confirm variable leaid_num
        if !_rc local keepvars `keepvars' leaid_num
        quietly keep `keepvars'
        if `first' {
            quietly save `acc', replace
            local first 0
        }
        else {
            append using `acc'
            quietly save `acc', replace
        }
    }
    use `acc', clear
    compress
    save "${raw}/ccd_directory.dta", replace
}
else {
    display as text "  Reusing data/raw/ccd_directory.dta"
    use "${raw}/ccd_directory.dta", clear
}

timer off 12
quietly timer list 12
display as result _n "CCD directory rows downloaded: " _N " districts in " %6.1f r(t12) " seconds"
record_runtime "01_ccd_directory" `=r(t12)'
tabulate fips

*------------------------------------------------------------------------------
* 1C. CCD enrollment by race (all grades, grade code 99)
*------------------------------------------------------------------------------
timer clear 13
timer on 13

capture confirm file "${raw}/ccd_enrollment_race.dta"
if _rc | `reuse' != 1 {
    tempfile acc
    local first 1
    foreach st in $STATES {
        display as text _n "  CCD enrollment by race: state FIPS `st'"
        fetch_or_stop "district ccd enrollment race" "year=${EDF_YEAR} fips=`st' grade=99"
        local keepvars leaid year fips race enrollment
        capture confirm variable leaid_num
        if !_rc local keepvars `keepvars' leaid_num
        quietly keep `keepvars'
        if `first' {
            quietly save `acc', replace
            local first 0
        }
        else {
            append using `acc'
            quietly save `acc', replace
        }
    }
    use `acc', clear
    compress
    save "${raw}/ccd_enrollment_race.dta", replace
}
else {
    display as text "  Reusing data/raw/ccd_enrollment_race.dta"
    use "${raw}/ccd_enrollment_race.dta", clear
}

timer off 13
quietly timer list 13
display as result _n "CCD enrollment rows downloaded: " _N " (district x race) in " ///
    %6.1f r(t13) " seconds"
record_runtime "01_ccd_enrollment" `=r(t13)'
tabulate fips

*------------------------------------------------------------------------------
* 1D. SAIPE: child poverty (ages 5 to 17) by school district
*------------------------------------------------------------------------------
timer clear 14
timer on 14

capture confirm file "${raw}/saipe_district.dta"
if _rc | `reuse' != 1 {
    tempfile acc
    local first 1
    foreach st in $STATES {
        display as text _n "  SAIPE: state FIPS `st'"
        fetch_or_stop "district saipe" "year=${EDF_YEAR} fips=`st'"
        quietly keep leaid year fips est_population_5_17 est_population_5_17_poverty_pct
        if `first' {
            quietly save `acc', replace
            local first 0
        }
        else {
            append using `acc'
            quietly save `acc', replace
        }
    }
    use `acc', clear
    compress
    save "${raw}/saipe_district.dta", replace
}
else {
    display as text "  Reusing data/raw/saipe_district.dta"
    use "${raw}/saipe_district.dta", clear
}

timer off 14
quietly timer list 14
display as result _n "SAIPE rows downloaded: " _N " districts in " %6.1f r(t14) " seconds"
record_runtime "01_saipe" `=r(t14)'
tabulate fips

tempname sf
file open `sf' using "${raw}/scope_stamp.txt", write replace text
file write `sf' "STATES=${STATES}|YEAR=${EDF_YEAR}|GRADES=${GRADES}" _n
file close `sf'

display as result _n "Download complete. Raw files are in data/raw and are not versioned."

log close step01
