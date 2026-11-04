/*==============================================================================
    run_all.do
    Master script: sets the study scope and paths, installs dependencies,
    runs the five pipeline steps in order and generates the two documents.

    Inputs       : none (every input is downloaded by code/01_download.do)
    Outputs      : the county-level datasets in data/derived, the tables,
                   figures and logs in output, and docs/index.html and
                   docs/replication.html
    Dependencies : Stata 17 or later; SSC packages educationdata (with
                   libjson), hetop and estout; internet connection
    Author       : Felipe Hernán Rodríguez Villalta
    Year         : 2026
==============================================================================*/

version 17
clear all
set more off
set linesize 120

*------------------------------------------------------------------------------
* The pipeline runs from the repository root, either in batch
* (for example: StataBE -e do run_all.do) or interactively after cd.
*------------------------------------------------------------------------------
capture confirm file "run_all.do"
if _rc {
    display as error "run_all.do must be run from the repository root, the folder that contains it."
    exit 601
}

*==============================================================================
* STUDY SCOPE
*
* These two globals define what the pipeline estimates. Every later script
* reads them, so redirecting the analysis to other states or another school
* year is a one-line edit here and nothing else.
*==============================================================================

global STATES "01 13 22 28 37 45"
*   State FIPS codes, space separated: 01 Alabama, 13 Georgia, 22 Louisiana,
*   28 Mississippi, 37 North Carolina, 45 South Carolina. Any set of states
*   works; the download loop runs once per state and grade. The six default
*   states have county-based school systems, so aggregating districts to
*   counties loses few students, and SEDA publishes county estimates for Black
*   and White students in grades 4, 6 and 8 for all six.

global EDF_YEAR 2018
*   School year, coded the way the portal codes it: the calendar year in which
*   the school year begins, so 2018 means 2018-19. The portal holds EDFacts
*   assessment results for 2009 to 2018 and for 2020 (2020-21, a pandemic year
*   with heavy suppression and uneven participation). SEDA codes a school year
*   by its spring, so 2018 here corresponds to 2019 in SEDA;
*   code/04_validate_seda.do makes that translation.

*==============================================================================
* OTHER PARAMETERS
*==============================================================================

global GRADES "4 6 8"
*   Tested grades. HETOP is fit separately for every county-grade cell and the
*   grade-level gaps are then pooled to one estimate per county.

global MIN_CELL_N 50
*   Minimum number of tested students in a district-grade-subgroup cell for the
*   cell to enter the county aggregate. Below this size EDFacts reports the
*   proficiency rate in wide ranges (10 points or more), and the Black-subgroup
*   HETOP estimates become unstable. The same threshold is applied again at the
*   county level: a county enters the sample only if its Black cell has at
*   least this many tested students in every grade.

global MAKE_MAP 1
*   1 draws the county map (Figure 2) with grmap and the Census cartographic
*   boundary file; 0 skips it. grmap ships with Stata 15 and later but must be
*   activated once with "grmap, activate", which writes an empty marker file
*   into the PERSONAL ado directory; the script performs the activation.

global SEDA_ACCEPT_DUA 0
*   The validation step downloads the SEDA county file from the Stanford
*   Digital Repository. SEDA is distributed under a data use agreement
*   (https://edopportunity.org/opportunity/data/): no commercial use, no
*   attempt to identify individuals, no redistribution of the files, and
*   acknowledgement of SEDA as the source. Read it, then set this global to 1.
*   With 0 the pipeline stops after step 03 and explains why.

global REUSE_RAW 0
*   1 reuses files already present in data/raw instead of downloading them
*   again, useful when re-running the analysis steps; the files are reused
*   only if they were downloaded for the same states, year and grades (step 01
*   keeps a scope stamp next to them). 0 downloads everything.

global RUN_STEPS "01 02 03 04 05 docs"
*   Steps to run, in order. The full list runs the whole pipeline; the
*   documents are built only when "docs" is listed. To redo only the figures
*   and the documents after a change, set it to "05 docs".

*==============================================================================
* PATHS (relative to the repository root; nothing below needs editing)
*==============================================================================

global root    "`c(pwd)'"
global code    "${root}/code"
global raw     "${root}/data/raw"
global derived "${root}/data/derived"
global tables  "${root}/output/tables"
global figures "${root}/output/figures"
global logs    "${root}/output/logs"
global docs    "${root}/docs"

foreach d in raw derived tables figures logs docs {
    capture mkdir "${`d'}"
}
capture mkdir "${docs}/figures"

* The companion command gapci and its help file live in code/ado
adopath ++ "${code}/ado"

*------------------------------------------------------------------------------
* Community packages. Installed from SSC only when missing.
*------------------------------------------------------------------------------
foreach pkg in educationdata hetop estout {
    capture which `pkg'
    if _rc {
        display as text "Installing `pkg' from SSC..."
        ssc install `pkg', replace
    }
}

*------------------------------------------------------------------------------
* Master log and runtime record. Each step also writes its own log.
*------------------------------------------------------------------------------
capture log close _all
log using "${logs}/00_run_all.log", replace text name(master)

* runtimes.csv keeps one row per step from the most recent run of that step:
* rows of the steps about to run are dropped, the others survive.
capture confirm file "${tables}/runtimes.csv"
if _rc {
    tempname fh
    file open `fh' using "${tables}/runtimes.csv", write replace text
    file write `fh' "step,seconds" _n
    file close `fh'
}
else {
    * (a global written as ${name} cannot sit on a foreach line: its brace
    * ends the command; a local carries the list instead)
    local steps_to_run ${RUN_STEPS}
    preserve
        quietly import delimited using "${tables}/runtimes.csv", clear varnames(1) stringcols(1) encoding(utf-8)
        foreach s of local steps_to_run {
            quietly drop if substr(step, 1, 2) == "`s'"
        }
        quietly drop if inlist(step, "docs", "total")
        quietly export delimited using "${tables}/runtimes.csv", replace
    restore
}

* record_runtime appends one row (step name, elapsed seconds) to runtimes.csv.
* The replication manual reads this file to report measured running times.
capture program drop record_runtime
program define record_runtime
    args step seconds
    tempname fh
    file open `fh' using "${tables}/runtimes.csv", write append text
    file write `fh' "`step',`seconds'" _n
    file close `fh'
end

* label_states attaches state names to a numeric state FIPS variable, for
* tables and figures. Usage: label_states varname
capture program drop label_states
program define label_states
    args v
    label define stfips 1 "Alabama" 2 "Alaska" 4 "Arizona" 5 "Arkansas"            ///
        6 "California" 8 "Colorado" 9 "Connecticut" 10 "Delaware"                  ///
        11 "District of Columbia" 12 "Florida" 13 "Georgia" 15 "Hawaii" 16 "Idaho" ///
        17 "Illinois" 18 "Indiana" 19 "Iowa" 20 "Kansas" 21 "Kentucky"             ///
        22 "Louisiana" 23 "Maine" 24 "Maryland" 25 "Massachusetts" 26 "Michigan"   ///
        27 "Minnesota" 28 "Mississippi" 29 "Missouri" 30 "Montana" 31 "Nebraska"   ///
        32 "Nevada" 33 "New Hampshire" 34 "New Jersey" 35 "New Mexico"             ///
        36 "New York" 37 "North Carolina" 38 "North Dakota" 39 "Ohio"              ///
        40 "Oklahoma" 41 "Oregon" 42 "Pennsylvania" 44 "Rhode Island"              ///
        45 "South Carolina" 46 "South Dakota" 47 "Tennessee" 48 "Texas" 49 "Utah"  ///
        50 "Vermont" 51 "Virginia" 53 "Washington" 54 "West Virginia"              ///
        55 "Wisconsin" 56 "Wyoming" 72 "Puerto Rico", replace
    label values `v' stfips
end

display as result _n "{hline 78}"
display as result " County achievement gaps: pipeline configuration"
display as result "{hline 78}"
display as result "   States (FIPS)      : ${STATES}"
display as result "   School year        : ${EDF_YEAR}-`=substr("`=${EDF_YEAR}+1'", 3, 2)' (portal year ${EDF_YEAR})"
display as result "   Grades             : ${GRADES}"
display as result "   Minimum cell size  : ${MIN_CELL_N}"
display as result "   Map                : ${MAKE_MAP}"
display as result "   SEDA DUA accepted  : ${SEDA_ACCEPT_DUA}"
display as result "   Reuse raw files    : ${REUSE_RAW}"
display as result "   Steps              : ${RUN_STEPS}"
display as result "   Stata              : `c(stata_version)' `c(edition)'"
display as result "{hline 78}" _n

*==============================================================================
* PIPELINE
*==============================================================================
timer clear 99
timer on 99

local scripts 01_download 02_build_master 03_estimate_gaps 04_validate_seda 05_figures_tables

foreach s of local scripts {
    local n = substr("`s'", 1, 2)
    if strpos(" ${RUN_STEPS} ", " `n' ") == 0 continue

    * The SEDA file may be downloaded only after the data use agreement has
    * been read and accepted (global SEDA_ACCEPT_DUA above).
    if "`n'" == "04" & ${SEDA_ACCEPT_DUA} != 1 {
        display as error _n "Step 04 needs the SEDA county file. Read the SEDA data use agreement at"
        display as error "https://edopportunity.org/opportunity/data/ and set SEDA_ACCEPT_DUA to 1 in"
        display as error `"run_all.do; then run again with RUN_STEPS set to "04 05 docs"."'
        log close master
        exit 1
    }

    display as result _n "{hline 78}"
    display as result " Running `s'.do"
    display as result "{hline 78}"
    timer clear `=real("`n'")'
    timer on `=real("`n'")'
    do "${code}/`s'.do"
    timer off `=real("`n'")'
    quietly timer list `=real("`n'")'
    record_runtime "`s'" `=r(t`=real("`n'")')'
    display as result " `s'.do finished in " %8.1f r(t`=real("`n'")') " seconds"
}

*------------------------------------------------------------------------------
* Documents. The replication manual (dyndoc, Markdown source) and the brief
* (dyntext, HTML source) read the results written above, so both documents
* always describe the run that produced them.
*------------------------------------------------------------------------------
if strpos(" ${RUN_STEPS} ", " docs ") > 0 {
    display as result _n "{hline 78}"
    display as result " Generating docs/replication.html and docs/index.html"
    display as result "{hline 78}"
    timer clear 90
    timer on 90
    dyndoc "${code}/replication.txt", saving("${docs}/replication.html") replace nomsg
    * dyndoc treats the included header as Markdown and wraps the doctype in
    * a paragraph; the declaration is restored so browsers render in standards mode
    quietly filefilter "${docs}/replication.html" "${docs}/replication.tmp", ///
        from("<p><!doctype html></p>") to("<!doctype html>") replace
    quietly copy "${docs}/replication.tmp" "${docs}/replication.html", replace
    erase "${docs}/replication.tmp"
    dyntext "${code}/brief.html", saving("${docs}/index.html") replace
    timer off 90
    quietly timer list 90
    record_runtime "docs" `=r(t90)'
    display as result " documents generated in " %8.1f r(t90) " seconds"
}

timer off 99
quietly timer list 99
record_runtime "total" `=r(t99)'

*------------------------------------------------------------------------------
* Stata fills the unused bytes of a dataset's name, format and label fields
* with whatever its memory held when the file was written, which can include
* local paths. Every shipped .dta file is rewritten with those bytes set to
* zero; data, labels and characteristics are untouched (scrubdta, code/ado).
*------------------------------------------------------------------------------
display as text _n "Zeroing the unused bytes of the shipped datasets..."
foreach d in derived tables {
    local dtafiles : dir "${`d'}" files "*.dta"
    foreach f of local dtafiles {
        scrubdta using "${`d'}/`f'"
        display as text "  `d'/`f': " r(bytes) " bytes set to zero"
    }
}

display as result _n "{hline 78}"
display as result " Pipeline complete. Total running time: " %8.1f r(t99) " seconds"
display as result " Logs in output/logs, tables in output/tables, figures in output/figures,"
display as result " derived county-level data in data/derived, documents in docs."
display as result "{hline 78}"

log close master

*------------------------------------------------------------------------------
* Stata writes the absolute path of the repository into every log header and
* file message, and the path of the temporary directory into the messages of
* tempfile saves. The logs are versioned, so once all logs are closed those two
* local paths are replaced by "." and "<tmpdir>" (a backslash, on Windows, is
* written as \BS for filefilter).
*------------------------------------------------------------------------------
local tmpdir = c(tmpdir)
local rootpath : subinstr global root "\" "\BS", all
local tmppath  : subinstr local tmpdir "\" "\BS", all
local logfiles : dir "${logs}" files "*.log"
foreach f of local logfiles {
    quietly filefilter "${logs}/`f'" "${logs}/`f'.tmp", from("`rootpath'") to(".") replace
    quietly filefilter "${logs}/`f'.tmp" "${logs}/`f'", from("`tmppath'") to("<tmpdir>/") replace
    erase "${logs}/`f'.tmp"
}
