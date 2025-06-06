% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/cpuLoad.R
\name{cpuLoad}
\alias{cpuLoad}
\title{Get the Recent CPU Load}
\usage{
cpuLoad()
}
\value{
A named numeric vector with three elements \verb{1min}, \verb{5min}, and
\verb{15min} with non-negative values.
These values represent estimates of the CPU load during the last minute,
the last five minutes, and the last fifteen minutes [1].
An idle system have values close to zero, and a heavily loaded system
have values near \code{parallel::detectCores()}.
If they are unknown, missing values are returned.
}
\description{
Get the Recent CPU Load
}
\details{
This function works only Unix-like system with \file{/proc/loadavg}.
}
\examples{
loadavg <- cpuLoad()
print(loadavg)
}
\references{
\enumerate{
\item Linux Load Averages: Solving the Mystery,
Brendan Gregg's Blog, 2017-08-08,
\url{https://www.brendangregg.com/blog/2017-08-08/linux-load-averages.html}
}
}
\keyword{internal}
