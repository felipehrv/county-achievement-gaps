*! gapci version 1.1.0  2026  Felipe Hernán Rodríguez Villalta
*! Standardized achievement gap (V statistic) and delta-method confidence
*! interval from two groups' HETOP estimates. See help gapci.

/*==============================================================================
    gapci.ado
    Returns the standardized gap V between two groups and its delta-method
    confidence interval from HETOP estimates of their means and SDs.

    Inputs       : eight scalars (mean, SE of mean, SD, SE of SD for each
                   group), passed as options
    Outputs      : displayed table; r(gap), r(gap_se), r(ci_lb), r(ci_ub),
                   r(level)
    Dependencies : Stata 17 or later; Mata (the arithmetic lives in
                   _gapci_core below)
    Author       : Felipe Hernán Rodríguez Villalta
    Year         : 2026

    V = (mu_1 - mu_2) / sqrt((sd_1^2 + sd_2^2) / 2) is the standardized
    difference of Ho (2009), used throughout the gap literature (Ho and
    Reardon 2012; Reardon and Ho 2015; Reardon, Shear, Castellano and Ho
    2017). Ho's V is invariant to increasing transformations of the test
    metric and equals this ratio under the normality assumed here. The standard
    error treats the four estimates as independent, which makes the interval
    approximate when they come from one fit. The companion Mata function
    compute_gaps_vec() in code/03_estimate_gaps.do applies the same formulas
    to every cell of a dataset at once; gapci is the single-comparison tool.
==============================================================================*/

capture program drop gapci
program define gapci, rclass
    version 17

    syntax , MEAN1(real) SE1(real) SD1(real) SDSE1(real)                        ///
             MEAN2(real) SE2(real) SD2(real) SDSE2(real)                        ///
             [ LEVel(cilevel) NOHeader ]

    if "`level'" == "" local level 95

    * Arithmetic delegated to Mata for clean matrix-form delta method.
    tempname gap gap_se ci_lb ci_ub
    mata: _gapci_core(`mean1', `se1', `sd1', `sdse1',                           ///
                      `mean2', `se2', `sd2', `sdse2', `level',                  ///
                      "`gap'", "`gap_se'", "`ci_lb'", "`ci_ub'")

    * Display
    if "`header'" == "" {
        display as text _n "{hline 60}"
        display as text " Standardized achievement gap (HETOP / V-statistic)"
        display as text "{hline 60}"
    }
    display as text    _col(3) "Group 1 (reference): "                          ///
                       "mean = " as result %7.3f `mean1'                        ///
                       as text "  SD = "   as result %7.3f `sd1'
    display as text    _col(3) "Group 2            : "                          ///
                       "mean = " as result %7.3f `mean2'                        ///
                       as text "  SD = "   as result %7.3f `sd2'
    display as text    _col(3) "{hline 54}"
    display as text    _col(3) "V statistic      = " as result %7.3f `gap'
    display as text    _col(3) "SE (delta method)= " as result %7.3f `gap_se'
    display as text    _col(3) "`level'% CI          = [" as result %7.3f `ci_lb' ///
                       as text ", " as result %7.3f `ci_ub' as text "]"
    if "`header'" == "" display as text "{hline 60}" _n

    * Return
    return scalar gap    = `gap'
    return scalar gap_se = `gap_se'
    return scalar ci_lb  = `ci_lb'
    return scalar ci_ub  = `ci_ub'
    return scalar level  = `level'
end


mata:

void _gapci_core(real scalar mu1, real scalar se_mu1,
                 real scalar sd1, real scalar se_sd1,
                 real scalar mu2, real scalar se_mu2,
                 real scalar sd2, real scalar se_sd2,
                 real scalar level,
                 string scalar gapname,  string scalar seName,
                 string scalar lbname,   string scalar ubname)
{
    real scalar pooled_sd, gap, z
    real scalar dV_dmu1, dV_dmu2, dV_dsd1, dV_dsd2, gap_var, gap_se

    pooled_sd = sqrt((sd1^2 + sd2^2) / 2)
    gap       = (mu1 - mu2) / pooled_sd

    // Delta-method gradients
    dV_dmu1 =   1 / pooled_sd
    dV_dmu2 =  -1 / pooled_sd
    dV_dsd1 = -(mu1 - mu2) * sd1 / (2 * pooled_sd^3)
    dV_dsd2 = -(mu1 - mu2) * sd2 / (2 * pooled_sd^3)

    gap_var = dV_dmu1^2 * se_mu1^2 +
              dV_dmu2^2 * se_mu2^2 +
              dV_dsd1^2 * se_sd1^2 +
              dV_dsd2^2 * se_sd2^2
    gap_se  = sqrt(gap_var)

    // Two-sided critical value
    z = invnormal(1 - (1 - level/100) / 2)

    st_numscalar(gapname, gap)
    st_numscalar(seName,  gap_se)
    st_numscalar(lbname,  gap - z * gap_se)
    st_numscalar(ubname,  gap + z * gap_se)
}

end

