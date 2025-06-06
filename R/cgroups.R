#-------------------------------------------------------
# Utility functions with option to override for testing
#-------------------------------------------------------
maxCores <- local({
  .max <- NULL
  
  function(max = NULL) {
    ## Set new max?
    if (!is.null(max)) {
      ## Reset?
      if (is.na(max)) max <- NULL
      old_max <- .max
      .max <<- max
      return(old_max)
    }

    ## Update cache?
    if (is.null(.max)) .max <<- parallel::detectCores(logical = TRUE)

    .max
  }
})


procPath <- local({
  .path <- NULL
  
  function(path = NULL) {
    ## Set new path?
    if (!is.null(path)) {
      ## Reset?
      if (is.na(path)) path <- NULL
      old_path <- .path
      .path <<- path

      ## Reset caches
      environment(getCGroupsRoot)$.cache <- list()
      environment(getCGroupsMounts)$.cache <- NULL
      environment(getCGroups)$.data <- NULL
      environment(maxCores)$.max <- NULL

      return(old_path)
    }

    ## Update cache?
    if (is.null(.path)) .path <<- "/proc"
    
    .path
  }
})


#' @importFrom utils read.table
readMounts <- function(file) {
  stopifnot(file_test("-f", file))

  ## A /proc/self/mounts file has lines of format:
  ## 
  ## <source> <target> <fstype> <options> <dump> <pass>
  ##
  ## where the fields are separated by SPACE:s. Now, some files
  ## may have syntax errors on some lines. For example, one
  ## Windows WSL2 user reports extraneous SPACE:s due to SPACEs
  ## in Windows paths (e.g. 'C:\\Program Files\\...') that are
  ## should have been escaped as '\\040' [1]. Because of this,
  ## we cannot assume everything is six fields and use:
  ##   data <- read.table(file, sep = " ")
  ## The Linux 'findmnt' tool ignores such misconfigured lines
  ## with a stderr note. We will do the same here.
  ## [1] https://github.com/futureverse/parallelly/issues/132
  ## NOTE: Some /proc/self/mounts files may have syntax eros

  ## Drop invalid lines
  lines <- readLines(file)
  parts <- strsplit(lines, split = " ", fixed = TRUE)
  ns <- vapply(parts, FUN.VALUE = NA_integer_, FUN = length)
  ## Drop misconfigured lines
  keep <- (ns == 6)
  invalid <- lines[!keep]
  names(invalid) <- which(!keep)
  lines <- lines[keep]

  ## Parse the valid lines
  data <- read.table(text = lines, sep = " ", stringsAsFactors = FALSE)

  names <- c("device", "mountpoint", "type", "options", "dump", "pass")
  if (ncol(data) < length(names)) {
    names <- names[seq_len(ncol(data))]
  } else if (ncol(data) > length(names)) {
    names <- c(names, rep("", ncol(data) - length(names)))
  }
  names(data) <- names

  ## Return invalid entries too
  if (length(invalid) > 0) attr(data, "invalid") <- invalid
  
  data
}


#' @importFrom utils write.table
writeMounts <- function(mounts, file) {
  write.table(mounts, file = file, quote = FALSE, sep = " ", row.names = FALSE, col.names = FALSE)
}

getUID <- local({
  .uid <- NULL
  
  function() {
    if (!is.null(.uid)) return(.uid)
    res <- system2("id", args = "-u", stdout = TRUE)
    uid <- as.integer(res)
    if (is.na(uid)) stop("id -u returned a non-integer: ", sQuote(res))
    .uid <<- uid
    uid
  }
})


#' @importFrom utils file_test tar
cloneCGroups <- function(tarfile = "cgroups.tar.gz") {
  ## Temporarily reset overrides
  old_path <- procPath(NA)
  on.exit(procPath(old_path))

  ## Create a temporary directory
  dest <- tempfile()
  dir.create(dest)
  stopifnot(file_test("-d", dest))
  on.exit(unlink(dest, recursive = TRUE), add = TRUE)

  ## Record current UID
  uid <- getUID()
  file <- file.path(dest, "uid")
  cat(uid, file = file)

  ## Cgroups controller
  controller <- NA_character_
  
  ## Record /proc/self/
  src <- file.path("/proc", "self")
  dir.create(file.path(dest, src), recursive = TRUE)

  ## Record /proc/self/cgroup
  file <- file.path(src, "cgroup")
  if (file_test("-f", file)) {
    bfr <- readLines(file, warn = FALSE)
    writeLines(bfr, con = file.path(dest, file))
  }
  
  ## Record /proc/self/mounts
  mounts <- getCGroupsMounts()

  ## Mixed CGroups versions are not supported
  utypes <- unique(mounts$type)

  controllers <- c()
   if ("cgroup" %in% utypes) {
    controllers <- c(controllers, "cpu", "cpuset")
  }
  if ("cgroup2" %in% utypes) {
    controllers <- c(controllers, "")
  }

  ## Write CGroups mountpoints
  writeMounts(mounts, file = file.path(dest, file.path(src, "mounts")))

  ## Get full CGroups folder structure
  cgroups <- getCGroups()

  ## Record CGroups mountpoints for select controllers
  for (controller in controllers) {
    mounts_tt <- NULL
    
    ## CGroups v1 or v2?
    if (nzchar(controller)) {
      ## CGroups v1
      pattern <- sprintf("\\b%s\\b", controller)
      
      mounts_tt <- mounts[grepl(pattern, mounts$mountpoint), ]
      if (nrow(mounts_tt) == 0) {
        ## No CGroups v1 mountpoint for specified controller
	next
      } else if (nrow(mounts_tt) > 1) {
        warning(sprintf("Detected more than one 'cgroup' mountpoint for CGroups v1 controller %s; using the first one", sQuote(controller)))
        mounts_tt <- mounts_tt[1, ]
      }

      cgroups_tt <- cgroups[cgroups$controller == controller, ]
      if (nrow(cgroups_tt) == 0) {
        ## No CGroups v1 for specified controller
	next
      } else if (nrow(cgroups_tt) > 1) {
        warning(sprintf("Detected more than one 'cgroup' for CGroups v1 controller %s; using the first one", sQuote(controller)))
        cgroups_tt <- cgroups_tt[1, ]
      }
    } else {
      mounts_tt <- mounts
      cgroups_tt <- cgroups
      
      if (nrow(mounts_tt) == 0) {
        ## No CGroups v2 mountpoint for specified controller
	next
      } else if (nrow(mounts_tt) > 1) {
        warning("Detected more than one 'cgroup2' mountpoint for CGroups v2; using the first one")
        mounts_tt <- mounts_tt[1, ]
      }
      
      if (nrow(cgroups_tt) == 0) {
        ## No CGroups v2 for specified controller
	next
      } else if (nrow(cgroups_tt) > 1) {
        warning("Detected more than one 'cgroup2' for CGroups v2; using the first one")
        cgroups_tt <- cgroups_tt[1, ]
      }
    }
    stopifnot(
      is.data.frame(mounts_tt),
      nrow(mounts_tt) == 1L,
      is.data.frame(cgroups_tt),
      nrow(cgroups_tt) == 1L
    )
    
    root <- mounts_tt$mountpoint
    path <- file.path(dest, root)
    dir.create(path, recursive = TRUE)

    paths <- character(0)
    for (dir in cgroups_tt$path) {
      paths <- c(paths, dir)
      while (nzchar(dir) && dir != "/") {
        dir <- dirname(dir)
        paths <- c(paths, dir)
      }
    }
    paths <- unique(paths)

    ## Copy file structure
    for (dir in paths) {
      src <- file.path(root, dir)
      if (!file_test("-d", src)) next
      path <- file.path(dest, src)
      if (!file_test("-d", path)) dir.create(path, recursive = TRUE)
      files <- dir(path = src)
      files <- files[file_test("-f", file.path(src, files))]
      for (file in files) {
        file.copy(file.path(src, file), file.path(path, file))
      }
    }
  } ## for (controller ...)

  local({
    opwd <- setwd(dest)
    on.exit(setwd(opwd))
    tar(file.path(opwd, tarfile), compression = "gzip")
  })
  
  tarfile
}


#' @importFrom utils file_test untar
withCGroups <- function(tarball, expr = NULL, envir = parent.frame(), tmpdir = NULL) {
   stopifnot(file_test("-f", tarball))
   expr <- substitute(expr)

   name <- sub("[.]tar[.]gz$", "", basename(tarball))
   message(sprintf("CGroups for system %s ...", sQuote(name)))

   ## Create a temporary temporary directory?
   if (is.null(tmpdir)) {
       tmpdir <- tempfile()
       dir.create(tmpdir)
       on.exit(unlink(tmpdir, recursive = TRUE))
   }
   message(" - Using temporary folder: ", sQuote(tmpdir))
   
   untar(tarball, exdir = tmpdir)

   ## Read the UID
   file <- file.path(tmpdir, "uid")
   if (file_test("-f", file)) {
     uid <- scan(file.path(tmpdir, "uid"), what = "integer", n = 1L, quiet = TRUE)
     uid <- as.integer(uid)
     message(sprintf(" - UID: %d", uid))
   }

   ## Clear all memoization caches
   fcns <- list(
     getCGroupsMounts, getCGroups, getCGroupsVersion,
     getCGroups1CpuSet, getCGroups1CpuPeriodMicroseconds, getCGroups1CpuQuota,
     getCGroups2CpuMax
   )
   for (fcn in fcns) {
     environment(fcn)$.cache <- NULL
   }
   fcns <- list(getCGroupsRoot, getCGroupsPath, getCGroupsValue)
   for (fcn in fcns) {
     environment(fcn)$.cache <- list()
   }

   ## Adjust /proc accordingly
   file <- file.path(tmpdir, "proc")
   if (file_test("-d", file)) {
     old_procPath <- procPath(file)
     on.exit(procPath(old_procPath), add = TRUE)
     message(sprintf(" - procPath(): %s", sQuote(procPath())))
   }

   ## Disable max CPU cores validation
   old_maxCores <- maxCores(Inf)
   on.exit(maxCores(old_maxCores), add = TRUE)
   message(sprintf(" - maxCores(): %s", maxCores()))

   ## Adjust /sys/fs/cgroup root accordingly
   message(" - Adjust /proc/self/mounts accordingly:")
   file <- file.path(tmpdir, "proc", "self", "mounts")
   if (file_test("-f", file)) {
     mounts <- readMounts(file)
     idxs <- which(mounts$type %in% c("cgroup", "cgroup2"))
     for (idx in idxs) {
       mounts[idx, "mountpoint"] <- normalizePath(file.path(tmpdir, mounts[idx, "mountpoint"]), winslash = "/", mustWork = FALSE)
     }
     writeMounts(mounts, file = file)
     bfr <- readLines(file, warn = FALSE)
     bfr <- sprintf("   %02d: %s", seq_along(bfr), bfr)
     writeLines(bfr)
   }

   message(" - getCGroupsVersion(): ", getCGroupsVersion())

   message(" - getCGroupsMounts():")
   mounts <- getCGroupsMounts()
   print(mounts)

   message(" - getCGroups():")
   cgroups <- getCGroups()
   print(cgroups)

   message(" - length(getCGroups1CpuSet()): ", length(getCGroups1CpuSet()))
   message(" - getCGroups1CpuQuota(): ", getCGroups1CpuQuota())
   message(" - getCGroups2CpuMax(): ", getCGroups2CpuMax())

   message(" - availableCores(which = 'all'):")
   cores <- availableCores(which = "all")
   print(cores)

   if (is.null(envir)) {
     res <- eval(expr)
   } else {
     res <- eval(expr, envir = envir)
   }
   
   message(sprintf("CGroups for system %s ... done", sQuote(name)))
   
   invisible(res)
}


#-------------------------------------------------------
# Unix control groups ("cgroups")
#-------------------------------------------------------
#  @return A character string to an existing CGroups root folder.
#  If no such folder could be found, NA_character_ is returned.
#
#' @importFrom utils file_test
getCGroupsRoot <- local({
  ## To please R CMD check
  type <- mountpoint <- NULL
  
  .cache <- list()
  
  function(controller = "") {
    stopifnot(is.character(controller), length(controller) == 1L, !is.na(controller))

    path <- .cache[[controller]]
    if (!is.null(path)) return(path)

    ## Look up the CGroups mountpoint
    mounts <- getCGroupsMounts()
    
    ## Filter by CGroups v1 or v2?
    if (nzchar(controller)) {
      mounts <- subset(mounts, type == "cgroup")
    } else {
      mounts <- subset(mounts, type == "cgroup2")
    }
    if (nrow(mounts) == 0) {
      path <- NA_character_
      .cache[[controller]] <<- path
      return(path)
    }

    if (nrow(mounts) > 1) {
      ## CGroups v1 or v2?
      if (nzchar(controller)) {
        ## CGroups v1
        pattern <- sprintf("\\b%s\\b", controller)
        mounts <- subset(mounts, grepl(pattern, mountpoint))
        if (nrow(mounts) == 0) {
          ## No such CGroups v1 mountpoint for specified controller
          path <- NA_character_
          .cache[[controller]] <<- path
          return(path)
        } else if (nrow(mounts) > 1) {
          warning(sprintf("Detected more than one 'cgroup' mountpoint for CGroups v1 controller %s; using the first one", sQuote(controller)))
          mounts <- mounts[1, ]
        }
      } else {
        ## CGroups v2
        warning("Detected more than one 'cgroup2' mountpoint for CGroups v2; using the first one")
        mounts <- mounts[1, ]
      }
    }

    stopifnot(nrow(mounts) == 1L)
    path <- mounts$mountpoint
    if (!file_test("-d", path)) {
      path <- NA_character_
    }
    
    .cache[[controller]] <<- path

    path
  }
})


#  Get the CGroups mountpoints
#
#  @return A data.frame with zero or more CGroups mountpoints.
#
#' @importFrom utils file_test
getCGroupsMounts <- local({
  ## To please R CMD check
  type <- NULL

  .cache <- NULL
  
  function() {
    file <- file.path(procPath(), "self", "mounts")
    
    ## cgroups is not set?
    if (!file_test("-f", file)) {
      mounts <- data.frame(device = character(0), mountpoint = character(0), type = character(0),
                           options = character(0), dump = integer(0), pass = integer(0))
      .cache <<- mounts
      return(mounts)
    }

    mounts <- readMounts(file)
    
    ## Keep CGroups mountpoints
    mounts <- subset(mounts, grepl("^cgroup", type))
  
    .cache <<- mounts
    mounts
  }
})


#  Get the CGroups hierarchy
#
#  @return A data frame with three columns:
#  * `hierarchy_id` (integer): 0 for cgroups v2.
#  * `controller` (string): The controller name for cgroups v1,
#    but empty for cgroups v2.
#  * `path` (string): The path to the CGroup in the hierarchy
#    that the process is part of.
#  If cgroups is not used, the an empty data.frame is returned.
# 
#' @importFrom utils file_test
getCGroups <- local({
  .cache <- NULL
  
  function() {
    data <- .cache
    if (!is.null(data)) return(data)

    ## Get cgroups
    file <- file.path(procPath(), "self", "cgroup")

    ## cgroups is not set?
    if (!file_test("-f", file)) {
      data <- data.frame(hierarchy_id = integer(0L), controller = character(0L), path = character(0L), stringsAsFactors = FALSE)
      .cache <<- data
      return(data)
    }

    ## Parse cgroups lines <hierarchy ID>:<controller>:<path>
    bfr <- readLines(file, warn = FALSE)
    pattern <- "^([[:digit:]]+):([^:]*):(.*)"
    bfr <- grep(pattern, bfr, value = TRUE)

    ids <- as.integer(sub(pattern, "\\1", bfr))
    controllers <- sub(pattern, "\\2", bfr)
    paths <- sub(pattern, "\\3", bfr)
    data <- data.frame(hierarchy_id = ids, controller = controllers, path = paths, stringsAsFactors = FALSE)
      
    ## Split multi-name entries into separate entries,
    ## e.g. 'cpuacct,cpu' -> 'cpuacct' and 'cpu'
    rows <- grep(",", data$controller)
    if (length(rows) > 0) {
      for (row in rows) {
        name <- data$controller[row]
        names <- strsplit(name, split = ",", fixed = TRUE)[[1]]
        data[row, "controller"] <- names[1]
        data2 <- data[row, ]
        for (name in names[-1]) {
          data2$controller <- name
          data <- rbind(data, data2)
        }
      }
    }
    
    ## Order by hierarchy ID
    data <- data[order(data$hierarchy_id), ]
    .cache <<- data
    
    data
  }
})


#  Get the path to a specific cgroups controller
#
#  @param controller (character) A cgroups v1 set or `""` for cgroups v2.
# 
#  @return An character string to an existing cgroups folder.
#  If no folder could be found, `NA_character_` is returned.
# 
#' @importFrom utils file_test
getCGroupsPath <- local({
  .cache <- list()
  
  function(controller) {
    res <- .cache[[controller]]
    if (!is.null(res)) return(res)
    
    root <- getCGroupsRoot(controller = controller)
    if (is.na(root)) {
      res <- NA_character_
      .cache[[controller]] <<- res
      return(res)
    }
  
    data <- getCGroups()
  
    set <- data[data$controller == controller, ]
    if (nrow(set) == 0L) {
      res <- NA_character_
      .cache[[controller]] <<- res
      return(res)
    }
  
    set <- set$path
    path <- file.path(root, set)
    while (set != "/") {
      if (file_test("-d", path)) {
        break
      }
      ## Should this ever happen?
      set_prev <- set
      set <- dirname(set)
      if (set == set_prev) break
      path <- file.path(root, set)
    }
  
    ## Should the following ever happen?
    if (!file_test("-d", path)) {
      res <- NA_character_
      .cache[[controller]] <<- res
    }
    
    res <- normalizePath(path, mustWork = FALSE)
    .cache[[controller]] <<- res
    res
  }
})


#  Get the value of specific cgroups controller and field
#
#  @param controller (character) A cgroups v1 set, or `""` for cgroups v2.
# 
#  @param field (character) A cgroups field.
# 
#  @return An character string.
#  If the requested cgroups controller and field could not be queried,
#  NA_character_ is returned.
#
#' @importFrom utils file_test
getCGroupsValue <- local({
  .cache <- list()
  
  function(controller, field) {
    cache_controller <- .cache[[controller]]
    if (!is.null(cache_controller)) {
      res <- cache_controller[[field]]
      if (!is.null(res)) return(res)
    }

    if (is.null(cache_controller)) {
      cache_controller <- list()
    }

    path <- getCGroupsPath(controller = controller)
    if (is.na(path)) {
      res <- NA_character_
      cache_controller[[field]] <- res
      .cache[[controller]] <<- cache_controller
      return(res)
    }
  
    path_prev <- ""
    while (path != path_prev) {
      file <- file.path(path, field)
      if (file_test("-f", file)) {
        value <- readLines(file, warn = FALSE)
        if (length(value) == 0L) value <- NA_character_
        attr(value, "path") <- path
        cache_controller[[field]] <- value
        .cache[[controller]] <<- cache_controller
        return(value)
      }
      path_prev <- path
      path <- dirname(path)
    }

    res <- NA_character_
    cache_controller[[field]] <- res
    .cache[[controller]] <<- cache_controller
    res
  }
})


#  Get the value of specific cgroups v1 field
#
#  @param controller (character) A cgroups v1 set.
#
#  @param field (character) A cgroups v1 field.
# 
#  @return An character string. If the requested cgroups v1 field could not be
#  queried, NA_character_ is returned.
#
getCGroups1Value <- function(controller, field) {
  getCGroupsValue(controller, field = field)
}


#  Get the value of specific cgroups v2 field
#
#  @param field (character) A cgroups v2 field.
# 
#  @return An character string. If the requested cgroups v2 field could not be
#  queried, NA_character_ is returned.
getCGroups2Value <- function(field) {
  getCGroupsValue("", field = field)
}


#  Get cgroups version
#
#  @return
#  If the current process is under cgroups v1, then `1L` is returned.
#  If it is under cgroups v2, then `2L` is returned.
#  If not under cgroups control, then `-1L` is returned.
#
getCGroupsVersion <- local({
  .cache <- NULL
  
  function() {
    res <- .cache
    
    if (!is.null(res)) return(res)
    
    cgroups <- getCGroups()
    if (nrow(cgroups) == 0) {
      res <- -1L
    } else if (nrow(cgroups) == 1 && cgroups$controller == "") {
      res <- 2L
    } else {
      res <- 1L
    }

    .cache <<- res
    
    res
  }
})



# --------------------------------------------------------------------------
# CGroups v1 CPU settings
# --------------------------------------------------------------------------
#  Get cgroups v1 'cpuset.cpus'
#
#  @return An integer vector of CPU indices. If cgroups v1 field
#  `cpuset.cpus` could not be queried, integer(0) is returned.
#
#  From 'CPUSETS' [1]:
#
#  cpuset.cpus: list of CPUs in that cpuset
#
#  [1] https://www.kernel.org/doc/Documentation/cgroup-v1/cpusets.txt
#
getCGroups1CpuSet <- local({
  .cache <- NULL
  
  function() {
    res <- .cache
    if (!is.null(res)) return(res)
    
    ## TEMPORARY: In case the cgroups options causes problems, make
    ## it possible to override their values via hidden options
    cpuset <- get_package_option("cgroups.cpuset", NULL)
    if (!is.null(cpuset)) return(cpuset)
  
    ## e.g. /sys/fs/cgroup/cpuset/cpuset.cpus
    value0 <- getCGroups1Value("cpuset", "cpuset.cpus")
    if (is.na(value0)) {
      res <- integer(0L)
      .cache <<- res
      return(res)
    }
    
    ## Parse 0-63; 0-7,9; 0-7,10-12; etc.
    code <- gsub("-", ":", value0, fixed = TRUE)
    code <- sprintf("c(%s)", code)
    expr <- tryCatch({
      parse(text = code)
    }, error = function(ex) {
      warning(sprintf("Syntax error parsing %s: %s", sQuote(file), sQuote(value0)))
      integer(0L)
    })
  
    value <- tryCatch({
      suppressWarnings(as.integer(eval(expr)))
    }, error = function(ex) {
      warning(sprintf("Failed to parse %s: %s", sQuote(file), sQuote(value0)))
      integer(0L)
    })
  
    ## Sanity checks
    max_cores <- maxCores()
    if (any(value < 0L | value >= max_cores)) {
      warning(sprintf("[INTERNAL]: Will ignore the cgroups CPU set, because it contains one or more CPU indices that is out of range [0,%d]: %s", max_cores - 1L, value0))
      value <- integer(0L)
    }
  
    if (any(duplicated(value))) {
      warning(sprintf("[INTERNAL]: Detected and dropped duplicated CPU indices in the cgroups CPU set: %s", value0))
      value <- unique(value)
    }
  
    cpuset <- value
    
    ## Should never happen, but just in case
    stop_if_not(length(cpuset) <= max_cores)

    .cache <<- cpuset

    cpuset
  }
})


#
#  From 'CPUSETS' [1]:
# 
# * `cpu.cfs_period_us`: The duration in microseconds of each scheduler
#     period, for bandwidth decisions. This defaults to 100000us or
#     100ms. Larger periods will improve throughput at the expense of
#     latency, since the scheduler will be able to sustain a cpu-bound
#     workload for longer. The opposite of true for smaller
#     periods. Note that this only affects non-RT tasks that are
#     scheduled by the CFS scheduler.
# 
# * `cpu.cfs_quota_us`: The maximum time in microseconds during each
#     `cfs_period_us` in for the current group will be allowed to
#     run. For instance, if it is set to half of `cpu_period_us`, the
#     cgroup will only be able to peak run for 50% of the time. One
#     should note that this represents aggregate time over all CPUs in
#     the system. Therefore, in order to allow full usage of two CPUs,
#     for instance, one should set this value to twice the value of
#     `cfs_period_us`.
#
#  [1] https://www.kernel.org/doc/Documentation/cgroup-v1/cpusets.txt
#
getCGroups1CpuQuotaMicroseconds <- function() {
  value <- suppressWarnings({
    ## e.g. /sys/fs/cgroup/cpu/cpu.cfs_quota_us
    as.integer(getCGroups1Value("cpu", "cpu.cfs_quota_us"))
  })

  value
}


getCGroups1CpuPeriodMicroseconds <- local({
  .cache <- NULL
  
  function() {
    res <- .cache
    if (!is.null(res)) return(res)

    value <- suppressWarnings({
      ## e.g. /sys/fs/cgroup/cpu/cpu.cfs_period_us
      as.integer(getCGroups1Value("cpu", "cpu.cfs_period_us"))
    })

    .cache <<- value
    value
  }
})


#  @return A non-negative numeric.
#  If cgroups is not in use, or could not be queried, NA_real_ is returned.
#
getCGroups1CpuQuota <- local({
  .cache <- NULL
  
  function() {
    res <- .cache
    if (!is.null(res)) return(res)
    
    ## TEMPORARY: In case the cgroups options causes problems, make
    ## it possible to override their values via hidden options
    quota <- get_package_option("cgroups.cpuquota", NULL)
    if (!is.null(quota)) return(quota)

    ms <- getCGroups1CpuQuotaMicroseconds()
    if (!is.na(ms) && ms < 0) ms <- NA_integer_
    
    total <- getCGroups1CpuPeriodMicroseconds()
    if (!is.na(total) && total < 0) total <- NA_integer_
    
    value <- ms / total
  
    if (!is.na(value)) {
      max_cores <- maxCores()
      if (!is.finite(value) || value <= 0.0 || value > max_cores) {
        warning(sprintf("[INTERNAL]: Will ignore the cgroups CPU quota, because it is out of range [1,%d]: %s", max_cores, value))
        value <- NA_real_
      }
    }
  
    .cache <<- value
    
    value
  }
})


# --------------------------------------------------------------------------
# CGroups v2 CPU settings
# --------------------------------------------------------------------------
#  @return A non-negative numeric.
#  If cgroups is not in use, or could not be queried, NA_real_ is returned.
#
#  From 'Control Group v2' documentation [1]:
#
#  `cpu.max`:
#   A read-write two value file which exists on non-root cgroups.
#   The default is "max 100000".
#
#   The maximum bandwidth limit.  It's in the following format:
#
#     $MAX $PERIOD
#
#   which indicates that the group may consume upto $MAX in each
#   $PERIOD duration.  `"max"` for $MAX indicates no limit.  If only
#   one number is written, $MAX is updated.
#
#  [1] https://docs.kernel.org/admin-guide/cgroup-v2.html
#
getCGroups2CpuMax <- local({
  .cache <- NULL
  
  function() {
    res <- .cache
    if (!is.null(res)) return(res)
    
    ## TEMPORARY: In case the cgroups options causes problems, make
    ## it possible to override their values via hidden options
    quota <- get_package_option("cgroups2.cpu.max", NULL)
    if (!is.null(quota)) return(quota)
  
    raw <- suppressWarnings({
      ## e.g. /sys/fs/cgroup/cpu.max
      getCGroups2Value("cpu.max")
    })
  
    if (is.na(raw)) {
      .cache <<- NA_real_
      return(.cache)
    }
    
    values <- strsplit(raw, split = "[[:space:]]+")[[1]]
    if (length(values) != 2L) {
      .cache <<- NA_real_
      return(.cache)
    }
  
    period <- as.integer(values[2])
    if (is.na(period) && period <= 0L) {
      .cache <<- NA_real_
      return(.cache)
    }
    
    max <- values[1]
    if (max == "max") {
      .cache <<- NA_real_
      return(.cache)
    }
    
    max <- as.integer(max)
    value <- max / period
    if (!is.na(value)) {
      max_cores <- maxCores()
      if (!is.finite(value) || value <= 0.0 || value > max_cores) {
        warning(sprintf("[INTERNAL]: Will ignore the cgroups v2 CPU quota, because it is out of range [1,%d]: %s", max_cores, value))
        value <- NA_real_
      }
    }
  
    .cache <<- value
    
    value
  }
})
