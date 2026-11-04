# County achievement gaps

A reproducible Stata and Mata pipeline that estimates county-level White-Black mathematics achievement gaps for grades 4, 6 and 8 in school year 2018-19, for 307 counties in Alabama, Georgia, Louisiana, Mississippi, North Carolina and South Carolina (355 counties meet the sample rule; 307 of them have a White cell large enough for a gap). The outcome is recovered with heteroskedastic ordered probit (HETOP) models from the proficiency rates that districts report to EDFacts; the covariates come from the Common Core of Data and from SAIPE; all three are downloaded from the Urban Institute Education Data Portal. The pipeline pools grade-level gaps into one estimate per county with precision weights, relates the county gaps to child poverty and school-district structure, validates the estimates against the Stanford Education Data Archive, and writes a brief and a replication manual from the results of the run itself.

- Brief: [felipehrv.github.io/county-achievement-gaps](https://felipehrv.github.io/county-achievement-gaps/)
- Replication manual: [felipehrv.github.io/county-achievement-gaps/replication.html](https://felipehrv.github.io/county-achievement-gaps/replication.html)

## Data

All inputs are downloaded by `code/01_download.do` from the [Urban Institute Education Data Portal](https://educationdata.urban.org/documentation/), which republishes the federal files without authentication, with the `educationdata` Stata package. The portal codes a school year by the calendar year in which it begins, so `EDF_YEAR 2018` is 2018-19.

| Source | Portal endpoint | Variables used |
|---|---|---|
| [EDFacts](https://www.ed.gov/data/edfacts-initiative), U.S. Department of Education: state assessment results by district | `school-districts/edfacts/assessments/{year}/grade-{g}/race/` | `leaid`, `fips`, `grade_edfacts`, `race`, `math_test_num_valid` (students tested), `math_test_pct_prof_midpt` (midpoint of the published range of the percent at or above proficient); the range limits are kept in the raw download (`data/raw`, not versioned) for reference |
| [Common Core of Data](https://nces.ed.gov/ccd/), National Center for Education Statistics: district directory and enrollment by race | `school-districts/ccd/directory/{year}/` and `school-districts/ccd/enrollment/{year}/grade-99/race/` | `leaid`, `county_code`, `enrollment`, `lea_name`; `race`, `enrollment` |
| [SAIPE](https://www.census.gov/programs-surveys/saipe.html), U.S. Census Bureau: child poverty by school district | `school-districts/saipe/{year}/` | `leaid`, `est_population_5_17`, `est_population_5_17_poverty_pct` |

The portal keeps the Department of Education's special codes, -1 missing or not reported, -2 not applicable and -3 suppressed, which `code/02_build_master.do` recodes to missing in every source, and counts for EDFacts, before anything is aggregated.

Portal citation, in the form the portal requests: EDFacts, Common Core of Data, and Small Area Income and Poverty Estimates, Education Data Portal (Version 0.27.0), Urban Institute, accessed November 3, 2026, https://educationdata.urban.org/documentation/, made available under the ODC Attribution License.

The validation step downloads the county file of the Stanford Education Data Archive, version 6.0, cohort-standardized scale (`seda_county_long_cs_6.0.dta`), from the Stanford Digital Repository. SEDA is distributed under a data use agreement that forbids redistribution of the files; the pipeline downloads it only after the user sets `SEDA_ACCEPT_DUA` to 1 in `run_all.do`, keeps it in `data/raw`, which git ignores, and publishes only correlations and figures. Citation, as the repository of record gives it: Reardon, S. F., Ho, A. D., Shear, B. R., Fahle, E. M., saliba, j., and Kalogrides, D. (2025). Stanford Education Data Archive (Version 6.0). https://purl.stanford.edu/xh833nn4025, https://doi.org/10.25740/xh833nn4025.

The county map and the county names use the Census Bureau's 2018 cartographic boundary file for counties at 1:20,000,000 (`cb_2018_us_county_20m`).

## Methods

The public assessment files report, for each district and student group, the share of students at or above the state's proficient standard, so scores are coarsened into categories and each state uses its own test and standard; differences in proficiency rates are not comparable across states or along the score distribution (Ho 2008). Ho and Reardon (2012) showed how to estimate a gap between two groups from such counts, and the HETOP model of Reardon, Shear, Castellano and Ho (2017) treats the categories as cuts through a continuous distribution and recovers each group's mean and standard deviation on a common scale. The pipeline fits one model per county and grade, with three groups (all students, White, Black) and the `hetop` command's `identify(sums)` constraint, which treats the groups symmetrically.

The public files carry a single cut, so the four categories HETOP needs are reconstructed from each group's proficiency rate under two explicit assumptions: scores are normal with unit variance within every group, and the state's cut scores sit at -1, 0 and 1 around the proficient standard. The data therefore identify the location of each group relative to the standard, and the distance between groups, but not the within-group spread. The gap is Ho's (2009) V, which under this normality equals the difference in means over the pooled standard deviation; it is computed with its delta-method standard error for every cell in one Mata operation (`compute_gaps_vec()`) and reproduced cell by cell by the companion command `gapci`. As a check on the model's standard errors, the gap is also computed directly as the difference of the probits of the two proficiency rates with a binomial standard error; the two estimates correlate at 0.999 and the binomial standard error is 1.30 times the HETOP one at the median, so both intervals are reported.

Grade-level gaps are pooled to one estimate per county with the precision-weighted random-intercept model of Hedges and Vevea (1998), the setup SEDA adapts for pooling (Fahle et al. 2026, SEDA technical documentation), implemented with `mixed` on data in which every term, the county intercept included, is multiplied by the square root of the weight. The pooled gaps are related to county characteristics in a ladder of four nested precision-weighted regressions with robust standard errors: child poverty, log number of districts, Black share of enrollment and the between-district dispersion of that share. The estimates are validated against SEDA by refitting HETOP across the counties of each state and grade, the design SEDA uses, and correlating means and gaps with SEDA's within states (Pearson and Spearman), after standardizing both within state and grade because the scales differ. The analysis is descriptive: gaps are read as differences in measured achievement between groups of students schooled under different conditions, and nothing in the pipeline identifies a causal effect.

## The gapci command

`gapci` returns the standardized gap V between two groups and its delta-method confidence interval from HETOP estimates of the groups' means and standard deviations. It lives in `code/ado` with its help file, which `help gapci` displays once `code/ado` is on the ado path (`run_all.do` adds it).

```
gapci, mean1(#) se1(#) sd1(#) sdse1(#) mean2(#) se2(#) sd2(#) sdse2(#) [level(#) noheader]
```

| Option | Meaning |
|---|---|
| `mean1()`, `se1()`, `sd1()`, `sdse1()` | mean, its standard error, standard deviation and its standard error for group 1, the reference group (required) |
| `mean2()`, `se2()`, `sd2()`, `sdse2()` | the same four quantities for group 2 (required) |
| `level(#)` | confidence level; default `level(95)` or the value of `set level` |
| `noheader` | suppress the title, its rules and the closing rule |

Stored results: `r(gap)`, `r(gap_se)`, `r(ci_lb)`, `r(ci_ub)`, `r(level)`. V is invariant to increasing transformations of the test scale; its standard error treats the four inputs as independent, so the interval is approximate when they come from one fit.

Example, the call `code/03_estimate_gaps.do` makes on the first county-grade cell of the sample (Autauga County, Alabama, grade 4; group 1 White, group 2 Black), with the cell's values as the log prints them:

```
. gapci, mean1(0.1831) se1(0.0388) sd1(0.9816) sdse1(0.0363) mean2(-0.4220) se2(0.0647) sd2(0.9861) sdse2(0.0611) level(95)

------------------------------------------------------------
 Standardized achievement gap (HETOP / V-statistic)
------------------------------------------------------------
  Group 1 (reference): mean =   0.183  SD =   0.982
  Group 2            : mean =  -0.422  SD =   0.986
  ------------------------------------------------------
  V statistic      =   0.615
  SE (delta method)=   0.080
  95% CI           = [  0.459,   0.771]
------------------------------------------------------------
```

The same script runs `gapci` on every one of the 901 county-grade cells and stops if any result differs from `compute_gaps_vec()` by more than 1e-9; in the published run the largest difference was 4.4e-16 in V and 1.1e-16 in its standard error.

## How to run

Requirements: Stata 17 or later (the published run used Stata 18.5, BE edition, on macOS), an internet connection, and three SSC packages. `run_all.do` installs any that is missing; to install them by hand:

```
ssc install educationdata
ssc install hetop
ssc install estout
```

`educationdata` installs its dependency `libjson` on first use. The map uses `grmap` and `spshape2dta`, which ship with Stata 15 and later; `grmap` needs a one-time activation that the script performs. `code/05_figures_tables.do` tries Stata's `copy` for the Census boundary file and falls back to `curl`, present on macOS and most Linux systems, when the Census server refuses Stata's client (it did on the machine of the published run); without either, the map is skipped and county names fall back to FIPS codes.

Steps:

1. Clone the repository and open Stata in its root.
2. Read the SEDA data use agreement at https://edopportunity.org/opportunity/data/ and set `SEDA_ACCEPT_DUA` to 1 in `run_all.do` (the repository ships it as 0; the published run had it set to 1). With 0 the pipeline stops after step 03 and says why.
3. Run `do run_all.do`, or in batch from the root:

```
/Applications/Stata/StataBE.app/Contents/MacOS/StataBE -e do run_all.do   (macOS; use the executable of your edition)
stata-mp -b do run_all.do                                                  (Linux or Unix)
```

Stata in batch mode returns exit code 0 even after an error, so read `output/logs/00_run_all.log`; an error appears as a line `r(#);`.

Measured running times for the published run (six states, 355 sample counties, 1,065 county-grade cells, on a laptop; `output/tables/runtimes.csv` and the logs record them):

| Step | Time |
|---|---|
| 01 Download from the portal (18 EDFacts requests, 6 per other source) | 14.8 minutes (EDFacts 6.7, CCD directory 6.0, CCD enrollment 1.3, SAIPE 0.8; one transient failure retried) |
| 02 Build the county files | 0.1 seconds |
| 03 HETOP for 1,065 cells, gaps, pooling, ladder | 59 seconds (0.06 seconds per cell) |
| 04 SEDA download (178 MB, 13 seconds) and 54 within-state HETOP fits (11 seconds) | 24 seconds |
| 05 Figures, map and tables | 5 seconds |
| Documents (dyndoc and dyntext) | under 1 second |
| Total | 16.3 minutes |

The portal's response time varies: four complete downloads of the same files took 10.1, 28.9, 9.5 and 14.8 minutes (15 to 45 seconds per EDFacts request).

`output/tables/runtimes.csv` records the time of the most recent run of each step. What appears where:

- `data/derived/`: `proficiency_counts.dta` (county by grade by subgroup), `county_covariates.dta`, `hetop_estimates.dta`, `gaps_cell_level.dta`, `gaps_county_level.dta`, `county_means_within_state.dta`, `county_names.dta`, `ladder_estimates.ster`; the two validation files that carry SEDA values are written here but not versioned.
- `data/raw/`: the four portal downloads, the SEDA file, the boundary files and a scope stamp; nothing in it is versioned.
- `output/tables/`: the two esttab tables in HTML and LaTeX, the county table (`county_gaps.csv` and `.html`), the state summary, the exclusion accounting, HETOP convergence, SEDA correlations, the pooling and ladder summaries, running times.
- `output/figures/`: Figures 1 to 3 in SVG and PNG and Figure 4 in PNG only (an SVG would carry the standardized SEDA values as coordinates); copies in `docs/figures/`.
- `output/logs/`: a log per step and a master log.
- `docs/`: `index.html` (the brief) and `replication.html` (the manual), generated at the end of the run.

## Design notes

Two globals at the top of `run_all.do` define the scope: `STATES`, a list of state FIPS codes, and `EDF_YEAR`, the school year in the portal's coding. Every script reads them; moving the analysis to other states or years is a one-line edit. Other parameters follow them: `GRADES`, `MIN_CELL_N` (the cell-size threshold, 50), `MAKE_MAP`, `SEDA_ACCEPT_DUA`, `REUSE_RAW` (reuse files already in `data/raw`; they are reused only if their scope stamp matches the current states, year and grades) and `RUN_STEPS` (which steps to run; the full list runs the pipeline and builds the documents, `"05 docs"` redoes only the figures and documents).

Scaling to national coverage: download time is driven by the number of requests (15 to 45 seconds per EDFacts state-grade request and 44 to 155 seconds per state for the other three sources across the four runs made), and HETOP by the number of cells (0.05 seconds each), so 51 states would need between about 75 minutes and 4 hours of downloads with the JSON client, depending on the portal's response, and about 8 minutes of HETOP for some 9,000 cells. For that scale the portal's bulk CSV files are the faster route: the EDFacts district assessment and CCD district enrollment files come one per year (about 115 to 155 MB each), the CCD district directory (231 MB) and SAIPE (31 MB) files cover all years, their names are listed by the API at `/api/v1/api-downloads/` and served under https://educationdata.urban.org/csv/, and the `educationdata` command's `csv` option downloads them; `import delimited` from them and `keep if` on `fips` replaces the request loop in `code/01_download.do`. The portal holds EDFacts district assessments for 2009 to 2018 and for 2020 (2020-21, a pandemic year with heavy suppression and no SEDA county comparator); SEDA covers 2009 to 2019 at the county level.

Decisions the code takes, and why:

- Special codes -1, -2 and -3 are recoded to missing in every source; for EDFacts they become extended missing values and every excluded district row carries its reason. The exclusion accounting is written to `output/tables/exclusions_district_cells.csv`; a state-level student total built from fewer than three district rows is withheld.
- District-grade-subgroup cells with fewer than `MIN_CELL_N` tested students are excluded before aggregation, because EDFacts publishes their rates in wide ranges and small-group HETOP estimates are unstable; in the published run the rule set aside 5.4% of Black test takers in the six states (3.4% to 7.5% by state).
- A county enters the sample only when it has a Black cell of at least `MIN_CELL_N` tested students in every grade of `GRADES`; a county with no kept cell in some grade fails the rule. Cells where the White group is missing (majority-Black counties with small White enrollment in every district) stay in the file but get no gap.
- Every merge uses the numeric value of the district id, because the portal zero-pads `leaid` in some files and not in others (SAIPE arrives without the leading zero), and a string merge silently loses every district in a state whose FIPS code starts with 0.
- Directory records whose county code lies in another state are dropped (one record in the published run).
- County counts are plain sums (`rawsum`) and county proficiency rates are means weighted by the number tested; the total precision of a county is likewise the plain sum of its cell weights, and the number of grades with a gap is a plain count.
- The composition and dispersion measures are computed over the districts that have a Black share in the enrollment file; the district count uses every district of the directory. A proficiency rate of exactly 0 or 100 would be bounded at 0.5 and 99.5 percent before the probit (none occurs in the published scope).
- Covariates missing for a sample county are filled with the sample mean and the count of imputed counties is written out; in the published run it was zero for every variable.
- The between-district measure is the enrollment-weighted standard deviation of district Black shares within the county, normalized to 0 to 1. It is zero by construction in single-district counties and does not capture sorting between schools inside a district.
- `hetop` is called with `identify(sums)` explicitly; the installed version of the command defaults to the reference-group identification although its help file says otherwise, and the standardized estimates are the same under either.
- In the pooling model every term is multiplied by the square root of the cell weight, the county intercept included, so that `mixed` fits the intended random-effects model with known sampling variances; the pooled gap of a county is its empirical Bayes intercept plus the fixed part at the middle grade of `GRADES`, and its standard error is computed from the sum of cell precisions, with both HETOP-based and binomial-based versions kept.

## Limitations

- The public files carry one cut per group, so the within-group spread is assumed, not estimated. The gaps are, in effect, differences of probits of proficiency rates placed on a standard-deviation scale; the HETOP intervals understate the uncertainty that the published rates warrant (the binomial standard errors are about 30% larger), and the pooled intervals do not carry the variation of a county's gap across grades (the residual variance of the pooling model is 3.4 where 1 would indicate well-calibrated cell standard errors).
- The sample is the 355 counties of six states with a district of at least 50 Black test takers in every grade, and the 307 among them with a district of at least 50 White test takers in at least one grade. Nothing is said about the other 163 counties of these states, and the association between gaps and district structure may differ in states with fragmented district systems.
- The regression ladder describes associations in one school year; it does not identify effects, and the count of districts is both a measure of institutional fragmentation and a marker of metropolitan size.
- Levels are not comparable with SEDA, whose estimates are linked to the NAEP scale; only orderings and linear associations within states are compared.
- Mathematics only, grades 4, 6 and 8, one school year, one pair of groups.

## Data protection

The sources are public and aggregated, but they describe students from underserved populations, and the pipeline treats them with the care an institutional review board would ask for. Cells suppressed by the Department of Education are dropped and never imputed, reconstructed or recovered by subtraction; complementary suppression is respected because every published estimate is a county aggregate of districts with at least 50 tested students in the subgroup, and the only numbers that refer to excluded cells are the state-level counts of rows and of students tested in the exclusion accounting, which are sums of published counts and carry no proficiency value. No table, figure or map reports an estimate for a cell with fewer than 50 tested students, and subgroup estimates are published at the county level only. Subtracting the White and Black counts of a county cell from its all-students count leaves a residual that mixes students of other race groups with the White and Black students of the district rows that the size rule or suppression excluded; every county count is a sum of district counts that EDFacts publishes, so the subtraction recovers nothing that the public district file does not already give. The raw downloads, the SEDA file and the boundary files are not versioned (`data/raw` is ignored by git), the merged validation files that carry SEDA values are ignored too, SEDA is cited rather than redistributed, and the validation figure is published as an image rather than as a vector file with the values as coordinates. Stata fills the unused bytes of a dataset's name and label fields with whatever its memory holds, which can include local paths; `run_all.do` zeroes those bytes in every shipped `.dta` file (`scrubdta`, in `code/ado`) and replaces the repository and temporary-directory paths in the logs. The replication manual has a section with the same rules and the counts of what each rule excluded.

## Repository structure

```
county-achievement-gaps/
  README.md
  LICENSE                      MIT, for the code
  CITATION.cff
  .gitignore
  run_all.do                   scope globals, paths, dependencies; runs the steps and the documents
  code/
    01_download.do             portal downloads to data/raw
    02_build_master.do         county files, exclusion accounting
    03_estimate_gaps.do        HETOP, gaps (Mata), direct check, pooling, ladder, gapci test
    04_validate_seda.do        SEDA download, within-state HETOP, correlations
    05_figures_tables.do       four figures, map, HTML tables
    ado/gapci.ado              the companion command
    ado/gapci.sthlp            its help file
    ado/scrubdta.ado           zeroes the unused bytes of a .dta file's name and label fields
    replication.txt            dyndoc source of the manual
    brief.html                 dyntext source of the brief
    doc_header.html            shared CSS for both documents
  data/
    raw/.gitkeep               downloads (ignored by git)
    derived/                   county-level datasets (versioned, about 1 MB)
  output/
    tables/  figures/  logs/
  docs/
    index.html                 the brief
    replication.html           the manual
    figures/                   copies of the figures used by both documents
```

## Citation

See `CITATION.cff`. In text: Rodríguez Villalta, F. H. (2026). County achievement gaps: White-Black mathematics gaps from EDFacts proficiency counts with heteroskedastic ordered probit models (Stata and Mata). https://github.com/felipehrv/county-achievement-gaps. Please also cite the data sources listed under Data.

## License

The code is released under the MIT License (see `LICENSE`). The data remain subject to their sources' terms: the portal's ODC Attribution License, the SEDA data use agreement and the Census Bureau's terms.

## Author

Felipe Hernán Rodríguez Villalta, Stanford University. GitHub: [felipehrv](https://github.com/felipehrv).

## Tooling

A large language model assisted with the scaffolding of the download loop, the inline comments and the HTML wrappers of the documents. The analytic decisions, the organization of the code and all substantive Stata and Mata code are the author's.

## References

- Hedges, L. V., and J. L. Vevea. 1998. Fixed- and random-effects models in meta-analysis. Psychological Methods 3(4): 486-504. https://doi.org/10.1037/1082-989X.3.4.486
- Ho, A. D. 2008. The problem with "proficiency": Limitations of statistics and policy under No Child Left Behind. Educational Researcher 37(6): 351-360. https://doi.org/10.3102/0013189X08323842
- Ho, A. D. 2009. A nonparametric framework for comparing trends and gaps across tests. Journal of Educational and Behavioral Statistics 34(2): 201-228. https://doi.org/10.3102/1076998609332755
- Ho, A. D., and S. F. Reardon. 2012. Estimating achievement gaps from test scores reported in ordinal "proficiency" categories. Journal of Educational and Behavioral Statistics 37(4): 489-517. https://doi.org/10.3102/1076998611411918
- Reardon, S. F. 2011. The widening academic achievement gap between the rich and the poor: New evidence and possible explanations. In G. J. Duncan and R. J. Murnane, eds., Whither Opportunity? Rising Inequality, Schools, and Children's Life Chances, 91-116. New York: Russell Sage Foundation.
- Reardon, S. F. 2016. School segregation and racial academic achievement gaps. RSF: The Russell Sage Foundation Journal of the Social Sciences 2(5): 34-57. https://doi.org/10.7758/RSF.2016.2.5.03
- Reardon, S. F., and A. D. Ho. 2015. Practical issues in estimating achievement gaps from coarsened data. Journal of Educational and Behavioral Statistics 40(2): 158-189. https://doi.org/10.3102/1076998615570944
- Reardon, S. F., D. Kalogrides, and K. Shores. 2019. The geography of racial/ethnic test score gaps. American Journal of Sociology 124(4): 1164-1221. https://doi.org/10.1086/700678
- Reardon, S. F., B. R. Shear, K. E. Castellano, and A. D. Ho. 2017. Using heteroskedastic ordered probit models to recover moments of continuous test score distributions from coarsened data. Journal of Educational and Behavioral Statistics 42(1): 3-45. https://doi.org/10.3102/1076998616666279
- Reardon, S. F., E. S. Weathers, E. M. Fahle, H. Jang, and D. Kalogrides. 2024. Is separate still unequal? New evidence on school segregation and racial academic achievement gaps. American Sociological Review 89(6): 971-1010. https://doi.org/10.1177/00031224241297263
- Shear, B. R., and S. F. Reardon. 2017. HETOP: Stata module for estimating heteroskedastic ordered probit models with ordered frequency data. Statistical Software Components S458287, Boston College Department of Economics, revised 15 July 2019. https://ideas.repec.org/c/boc/bocode/s458287.html
- Shear, B. R., and S. F. Reardon. 2021. Using pooled heteroskedastic ordered probit models to improve small-sample estimates of latent test score distributions. Journal of Educational and Behavioral Statistics 46(1): 3-33. https://doi.org/10.3102/1076998620922919
- Fahle, E. M., saliba, j., Reardon, S. F., Shear, B. R., Kalogrides, D., and Ho, A. D. 2026. Stanford Education Data Archive: Technical Documentation (Version 6.0). https://purl.stanford.edu/xh833nn4025
