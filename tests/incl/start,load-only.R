## Record original state
ovars <- ls()
oenvs <- oenvs0 <- Sys.getenv()
oopts0 <- options()

covr_testing <- ("covr" %in% loadedNamespaces())
on_solaris <- grepl("^solaris", R.version$os)
on_macos <- grepl("^darwin", R.version$os)
on_githubactions <- as.logical(Sys.getenv("GITHUB_ACTIONS", "FALSE"))

## Default options
oopts <- options(
  warn = 1L,
  mc.cores = 2L,
  parallelly.slurm_expand_nodelist.manual = TRUE,
  parallelly.debug = TRUE
)

## Comment: The below should be set automatically whenever the package is
## loaded and 'R CMD check' runs.  The below is added in case R is changed
## in the future and we fail to detect 'R CMD check'.
Sys.setenv(R_PARALLELLY_MAKENODEPSOCK_CONNECTTIMEOUT = 2 * 60)
Sys.setenv(R_PARALLELLY_MAKENODEPSOCK_TIMEOUT = 2 * 60)
Sys.setenv(R_PARALLELLY_MAKENODEPSOCK_SESSIONINFO_PKGS = TRUE)

## Label PSOCK cluster workers (to help troubleshooting)
test_script <- grep("[.]R$", commandArgs(), value = TRUE)[1]
if (is.na(test_script)) test_script <- "UNKNOWN"
worker_label <- sprintf("parallelly/tests/%s:%s:%s:%s", test_script, Sys.info()[["nodename"]], Sys.info()[["user"]], Sys.getpid())
Sys.setenv(R_PARALLELLY_MAKENODEPSOCK_RSCRIPT_LABEL = worker_label)

fullTest <- (Sys.getenv("_R_CHECK_FULL_") != "")
isWin32 <- (.Platform$OS.type == "windows" && .Platform$r_arch == "i386")
useXDR <- parallelly:::getOption2("parallelly.makeNodePSOCK.useXDR", FALSE)

## Private functions
detectCores <- parallelly:::detectCores
hpaste <- parallelly:::hpaste
inRCmdCheck <- parallelly:::inRCmdCheck
mdebug <- parallelly:::mdebug
mdebugf <- parallelly:::mdebugf
pid_exists <- parallelly:::pid_exists
isFALSE <- parallelly:::isFALSE
isNA <- parallelly:::isNA

## Local functions for test scripts
printf <- function(...) cat(sprintf(...))
