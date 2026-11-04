{smcl}
{* *! version 1.1.0  2026  Felipe Hernán Rodríguez Villalta}{...}
{* gapci.sthlp: help file for gapci, the standardized gap V between two groups with a delta-method confidence interval from HETOP estimates}{...}
{* Inputs: eight scalars (mean, SE of mean, SD, SE of SD for each group), passed as options}{...}
{* Outputs: displayed table; r(gap), r(gap_se), r(ci_lb), r(ci_ub), r(level)}{...}
{* Dependencies: Stata 17 or later; Mata; hetop (SSC) for the examples}{...}
{* Author: Felipe Hernán Rodríguez Villalta, 2026}{...}
{vieweralsosee "hetop" "help hetop"}{...}
{viewerjumpto "Syntax" "gapci##syntax"}{...}
{viewerjumpto "Description" "gapci##description"}{...}
{viewerjumpto "Options" "gapci##options"}{...}
{viewerjumpto "Remarks" "gapci##remarks"}{...}
{viewerjumpto "Stored results" "gapci##results"}{...}
{viewerjumpto "Examples" "gapci##examples"}{...}
{viewerjumpto "References" "gapci##references"}{...}
{viewerjumpto "Author" "gapci##author"}{...}
{title:Title}

{phang}
{bf:gapci} {hline 2} Standardized achievement gap between two groups, with a
delta-method confidence interval, from HETOP estimates


{marker syntax}{...}
{title:Syntax}

{p 8 16 2}
{cmd:gapci}{cmd:,}
{opt mean1(#)} {opt se1(#)} {opt sd1(#)} {opt sdse1(#)}
{opt mean2(#)} {opt se2(#)} {opt sd2(#)} {opt sdse2(#)}
[{opt lev:el(#)} {opt noh:eader}]

{synoptset 12 tabbed}{...}
{synopthdr}
{synoptline}
{syntab:Required}
{synopt:{opt mean1(#)}}estimated mean of group 1, the reference group{p_end}
{synopt:{opt se1(#)}}standard error of {opt mean1()}{p_end}
{synopt:{opt sd1(#)}}estimated standard deviation of group 1{p_end}
{synopt:{opt sdse1(#)}}standard error of {opt sd1()}{p_end}
{synopt:{opt mean2(#)}}estimated mean of group 2{p_end}
{synopt:{opt se2(#)}}standard error of {opt mean2()}{p_end}
{synopt:{opt sd2(#)}}estimated standard deviation of group 2{p_end}
{synopt:{opt sdse2(#)}}standard error of {opt sd2()}{p_end}

{syntab:Optional}
{synopt:{opt lev:el(#)}}confidence level; default is {cmd:level(95)}{p_end}
{synopt:{opt noh:eader}}suppress the title, its rules and the closing rule{p_end}
{synoptline}
{p2colreset}{...}


{marker description}{...}
{title:Description}

{pstd}
{cmd:gapci} computes the standardized gap between two groups whose latent
achievement distributions have been estimated with a heteroskedastic ordered
probit model, for example with {helpb hetop}. The gap is the {it:V} statistic
of Ho (2009),

{p 8 12 2}
{it:V} = ({it:mu1} - {it:mu2}) / sqrt(({it:sd1}^2 + {it:sd2}^2) / 2),

{pstd}
the difference in means divided by the pooled standard deviation of the two
groups. Ho's {it:V} is defined without reference to a scale and does not
change when the test scale is transformed by any increasing function of
scores, which makes gaps comparable across tests and states (Ho and Reardon
2012; Reardon and Ho 2015); under the normality assumed by the HETOP model it
equals the ratio above. Its standard error is
obtained by the delta method from the four estimates and their standard
errors, treating the four as independent. A positive value means that group 1
has the higher mean.

{pstd}
The eight inputs are scalars, so the command fits one pair of groups at a
time. The same formulas, applied to every row of a dataset at once, are
implemented in the Mata function {cmd:compute_gaps_vec()} of the pipeline
that ships with this command; {cmd:gapci} reproduces its results to
numerical precision and is meant for single comparisons and for reporting.


{marker options}{...}
{title:Options}

{dlgtab:Required}

{phang}
{opt mean1(#)}, {opt se1(#)}, {opt sd1(#)} and {opt sdse1(#)} give the
estimated mean, its standard error, the estimated standard deviation and
its standard error for group 1, the reference group. All four are required.

{phang}
{opt mean2(#)}, {opt se2(#)}, {opt sd2(#)} and {opt sdse2(#)} give the same
four quantities for group 2. All four are required.

{dlgtab:Optional}

{phang}
{opt level(#)} sets the confidence level, as a percentage, for the interval.
The default is {cmd:level(95)} or as set by {helpb set level}.

{phang}
{opt noheader} suppresses the title with its rules and the closing rule, so
that the output can be embedded in other displays.


{marker remarks}{...}
{title:Remarks}

{pstd}
The estimates passed to {cmd:gapci} should be on a common metric for the two
groups. With {helpb hetop} that metric is the standardized one in which the
command reports {cmd:e(mstar)} and {cmd:e(sstar)}, with standard errors in
{cmd:e(mstar_se)} and {cmd:e(sstar_se)}; any other metric in which the two
groups share cut scores works equally well, because {it:V} is invariant to
the choice.

{pstd}
The delta-method variance treats the four input estimates as independent.
When they come from one HETOP fit they are correlated, and the interval is
then approximate.


{marker results}{...}
{title:Stored results}

{pstd}
{cmd:gapci} stores the following in {cmd:r()}:

{synoptset 15 tabbed}{...}
{p2col 5 15 19 2: Scalars}{p_end}
{synopt:{cmd:r(gap)}}the standardized gap {it:V}{p_end}
{synopt:{cmd:r(gap_se)}}delta-method standard error of {it:V}{p_end}
{synopt:{cmd:r(ci_lb)}}lower limit of the confidence interval{p_end}
{synopt:{cmd:r(ci_ub)}}upper limit of the confidence interval{p_end}
{synopt:{cmd:r(level)}}confidence level{p_end}
{p2colreset}{...}


{marker examples}{...}
{title:Examples}

{pstd}
A gap of about half a standard deviation, with a 95% interval{p_end}
{phang2}{cmd:. gapci, mean1(0.35) se1(0.04) sd1(1.02) sdse1(0.03) mean2(-0.15) se2(0.05) sd2(0.98) sdse2(0.04)}{p_end}

{pstd}
The same comparison with a 90% interval and no header{p_end}
{phang2}{cmd:. gapci, mean1(0.35) se1(0.04) sd1(1.02) sdse1(0.03) mean2(-0.15) se2(0.05) sd2(0.98) sdse2(0.04) level(90) noheader}{p_end}

{pstd}
After {cmd:hetop}, for groups 2 and 3 of a fit{p_end}
{phang2}{cmd:. hetop group ncat, numcats(4) identify(sums)}{p_end}
{phang2}{cmd:. matrix m = e(mstar)}{p_end}
{phang2}{cmd:. matrix s = e(sstar)}{p_end}
{phang2}{cmd:. matrix mse = e(mstar_se)}{p_end}
{phang2}{cmd:. matrix sse = e(sstar_se)}{p_end}
{phang2}{cmd:. gapci, mean1(`=m[2,1]') se1(`=mse[2,1]') sd1(`=s[2,1]') sdse1(`=sse[2,1]') mean2(`=m[3,1]') se2(`=mse[3,1]') sd2(`=s[3,1]') sdse2(`=sse[3,1]')}{p_end}


{marker references}{...}
{title:References}

{phang}
Ho, A. D. 2009. A nonparametric framework for comparing trends and gaps
across tests. {it:Journal of Educational and Behavioral Statistics} 34(2):
201-228.

{phang}
Ho, A. D., and S. F. Reardon. 2012. Estimating achievement gaps from test
scores reported in ordinal "proficiency" categories.
{it:Journal of Educational and Behavioral Statistics} 37(4): 489-517.

{phang}
Reardon, S. F., and A. D. Ho. 2015. Practical issues in estimating
achievement gaps from coarsened data.
{it:Journal of Educational and Behavioral Statistics} 40(2): 158-189.

{phang}
Reardon, S. F., B. R. Shear, K. E. Castellano, and A. D. Ho. 2017. Using
heteroskedastic ordered probit models to recover moments of continuous test
score distributions from coarsened data.
{it:Journal of Educational and Behavioral Statistics} 42(1): 3-45.


{marker author}{...}
{title:Author}

{pstd}
Felipe Hernán Rodríguez Villalta, Stanford University.{break}
Part of the county achievement gaps replication repository,
{browse "https://github.com/felipehrv/county-achievement-gaps"}.
