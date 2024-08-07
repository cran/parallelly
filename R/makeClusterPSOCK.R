#' Create a PSOCK Cluster of R Workers for Parallel Processing
#' 
#' The `makeClusterPSOCK()` function creates a cluster of \R workers
#' for parallel processing.  These \R workers may be background \R sessions
#' on the current machine, \R sessions on external machines (local or remote),
#' or a mix of such. For external workers, the default is to use SSH to
#' connect to those external machines.  This function works similarly to
#' \code{\link[parallel:makeCluster]{makePSOCKcluster}()} of the
#' \pkg{parallel} package, but provides additional and more flexibility
#' options for controlling the setup of the system calls that launch the
#' background \R workers, and how to connect to external machines.
#'
#' @param workers The hostnames of workers (as a character vector) or the
#' number of localhost workers (as a positive integer).
#' 
#' @param makeNode A function that creates a `"SOCKnode"` or
#' `"SOCK0node"` object, which represents a connection to a worker.
#' 
#' @param port The port number of the master used for communicating with all
#' the workers (via socket connections).  If an integer vector of ports, then
#' a random one among those is chosen.  If `"random"`, then a random port in
#' is chosen from `11000:11999`, or from the range specified by
#' environment variable \env{R_PARALLELLY_RANDOM_PORTS}.
#' If `"auto"` (default), then the default (single) port is taken from
#' environment variable \env{R_PARALLEL_PORT}, otherwise `"random"` is
#' used.
#' _Note, do not use this argument to specify the port number used by
#' `rshcmd`, which typically is an SSH client.  Instead, if the SSH daemon
#' runs on a different port than the default 22, specify the SSH port by
#' appending it to the hostname, e.g. `"remote.server.org:2200"` or via
#' SSH options \option{-p}, e.g. `rshopts = c("-p", "2200")`._
#' 
#' @param \dots Optional arguments passed to
#' `makeNode(workers[i], ..., rank = i)` where `i = seq_along(workers)`.
#'
#' @param autoStop If TRUE, the cluster will be automatically stopped
#' using \code{\link[parallel:makeCluster]{stopCluster}()} when it is
#' garbage collected, unless already stopped.  See also [autoStopCluster()].
#'
#' @param tries,delay Maximum number of attempts done to launch each node
#' with `makeNode()` and the delay (in seconds) in-between attempts.
#' If argument `port` specifies more than one port, e.g. `port = "random"`
#' then a random port will be drawn and validated at most `tries` times.
#' Arguments `tries` and `delay` are used only when
#' `setup_strategy == "sequential"`.
#'
#' @param validate If TRUE (default), after the nodes have been created,
#' they are all validated that they work by inquiring about their session
#' information, which is saved in attribute `session_info` of each node.
#'
#' @param verbose If TRUE, informative messages are outputted.
#'
#' @return An object of class `c("RichSOCKcluster", "SOCKcluster", "cluster")`
#' consisting of a list of `"SOCKnode"` or `"SOCK0node"` workers (that also
#' inherit from `RichSOCKnode`).
#'
#' @section Alternative usage:
#' In R (>= 4.4.0), an alternatively to using
#' `cl <- parallelly::makeClusterPSOCK(workers)` is:
#'
#' ```
#' cl <- parallel::makeCluster(workers, type = parallelly::PSOCK)
#' ```
#'
#' @example incl/makeClusterPSOCK.R
#'
#' @aliases PSOCK
#' @importFrom parallel stopCluster
#' @export
makeClusterPSOCK <- function(workers, makeNode = makeNodePSOCK, port = c("auto", "random"), ..., autoStop = FALSE, tries = getOption2("parallelly.makeNodePSOCK.tries", 3L), delay = getOption2("parallelly.makeNodePSOCK.tries.delay", 15.0), validate = getOption2("parallelly.makeNodePSOCK.validate", TRUE), verbose = getOption2("parallelly.debug", FALSE)) {
  verbose_prefix <- "[local output] "
  if (verbose) {
    oopts <- options(parallelly.debug = verbose)
    on.exit(options(oopts))
    mdebugf("%smakeClusterPSOCK() ...", verbose_prefix)
  }
  
  localhostHostname <- getOption2("parallelly.localhost.hostname", "localhost")

  if (is.numeric(workers)) {
    if (length(workers) != 1L) {
      stopf("When numeric, argument 'workers' must be a single value: %s", length(workers))
    }
    
    workers <- structure(as.integer(workers), class = class(workers))
    if (is.na(workers) || workers < 1L) {
      stopf("Number of 'workers' must be one or greater: %s", workers)
    }

    ## Warn, or refuse to continue, if too many localhost workers are requests   
    checkNumberOfLocalWorkers(workers)
    
    workers <- rep(localhostHostname, times = workers)
  }

  tries <- as.integer(tries)
  stop_if_not(length(tries) == 1L, is.integer(tries), !is.na(tries), tries >= 1L)

  delay <- as.numeric(delay)
  stop_if_not(length(delay) == 1L, is.numeric(delay), !is.na(delay), delay >= 0)

  validate <- as.logical(validate)
  stop_if_not(length(validate) == 1L, is.logical(validate), !is.na(validate))

  ## If we are sure that each node requires a connection, then ...
  if (identical(makeNode, makeNodePSOCK)) {
    ## ... can we create that many workers?
    free <- freeConnections()
    if (validate) free <- free - 1L
    if (length(workers) > free) {
      msg <- sprintf("Cannot create %d parallel PSOCK nodes. Each node needs one connection, but there are only %d connections left out of the maximum %d available on this R installation", length(workers), free, availableConnections())
      if (getRversion() >= "4.4.0") {
        msg <- sprintf("%s. To increase this limit in R (>= 4.4.0), use command-line option '--max-connections=N' when launching R.", msg)
      }
      stopf(msg)
    }
  }

  if (verbose) {
    mdebugf("%sWorkers: [n = %d] %s", verbose_prefix,
                    length(workers), hpaste(sQuote(workers)))
  }

  if (length(port) == 0L) {
    stop("Argument 'port' must be of length one or more: 0")
  }
  
  port_org <- port
  port <- freePort(port)
  if (verbose) mdebugf("%sBase port: %d", verbose_prefix, port)
  if (is.na(port)) {
    stop("Argument 'port' specifies non-available port(s): ", paste(port_org, collapse = ", "))
  }
  
  n <- length(workers)
  nodeOptions <- vector("list", length = n)
  if (verbose) mdebugf("%sGetting setup options for %d cluster nodes ...", verbose_prefix, n)
  for (ii in seq_len(n)) {
    if (verbose) mdebugf("%s - Node #%d of %d ...", verbose_prefix, ii, n)
    options <- makeNode(workers[[ii]], port = port, ..., rank = ii, action = "options", verbose = verbose)
    stop_if_not(inherits(options, "makeNodePSOCKOptions"))
    nodeOptions[[ii]] <- options
  }
  if (verbose) mdebugf("%sGetting setup options for %d cluster nodes ... done", verbose_prefix, n)

  ## Is a 'parallel' setup strategy requested and possible?
  setup_strategy <- lapply(nodeOptions, FUN = function(options) {
    value <- options$setup_strategy
    if (is.null(value)) value <- "sequential"
    stop_if_not(is.character(value), length(value) == 1L)
    value
  })
  setup_strategy <- unlist(setup_strategy, use.names = FALSE)
  is_parallel <- (setup_strategy == "parallel")
  force_sequential <- FALSE
  if (any(is_parallel)) {
    if (verbose) mdebugf("%s - Parallel setup requested for some PSOCK nodes", verbose_prefix)

    if (!all(is_parallel)) {
      if (verbose) mdebugf("%s - Parallel setup requested only for some PSOCK nodes; will revert to a sequential setup for all", verbose_prefix)
      force_sequential <- TRUE
    } else {
      ## Force setup_strategy = "sequential"?
      affected <- affected_by_bug18119()
      if (!is.na(affected) && affected) {
        if (verbose) mdebugf("%s - Parallel setup requested but not supported on this version of R: %s", verbose_prefix, getRversion())
        force_sequential <- TRUE
      }
    }
  }

  if (force_sequential) {
    ## Force all nodes to be setup using the 'sequential' setup strategy
    setup_strategy <- "sequential"

    for (ii in which(is_parallel)) {
      if (verbose) mdebugf("%s - Node #%d of %d ...", verbose_prefix, ii, n)
      args <- list(workers[[ii]], port = port, ..., rank = ii, action = "options", verbose = verbose)
      args$setup_strategy <- "sequential"
      options <- do.call(makeNode, args = args)
      stop_if_not(inherits(options, "makeNodePSOCKOptions"))
      nodeOptions[[ii]] <- options
    }
  }

  stopifnot(length(nodeOptions) == n)

  ## Sanity check
  setup_strategy <- lapply(nodeOptions, FUN = function(options) {
    value <- options$setup_strategy
    if (is.null(value)) value <- "sequential"
    stop_if_not(is.character(value), length(value) == 1L)
    value
  })
  stopifnot(length(setup_strategy) == n)
  setup_strategy <- unlist(setup_strategy, use.names = FALSE)
  setup_strategy <- unique(setup_strategy)
  stop_if_not(length(setup_strategy) == 1L)

  cl <- vector("list", length = length(nodeOptions))
  class(cl) <- c("RichSOCKcluster", "SOCKcluster", "cluster")
  stopifnot(length(cl) == length(nodeOptions))
  
  ## If an error occurred, make sure to clean up before exiting, i.e.
  ## stop each node
  on.exit({
    nodes <- vapply(cl, FUN = inherits, c("SOCKnode", "SOCK0node"),
                        FUN.VALUE = FALSE)
    stopCluster(cl[nodes])
    cl <- NULL
  }, add = TRUE)

  if (setup_strategy == "parallel") {
    ## To please R CMD check on R (< 4.0.0)
    if (getRversion() < "4.0.0") {
      stopf("Parallel setup of PSOCK cluster nodes is not supported in R %s", getRversion())
      socketAccept <- serverSocket <- function(...) NULL
    }
    
    sendCall <- importParallel("sendCall")
    recvResult <- importParallel("recvResult")
    
    ## AD HOC: Use (port, timeout, useXDR) from the options of the first node
    options <- nodeOptions[[1]]
    if (verbose) {
      mdebugf("%sSetting up PSOCK nodes in parallel", verbose_prefix)
      mstr(options)
    }
    port <- options[["port"]]
    connectTimeout <- options[["connectTimeout"]]
    timeout <- options[["timeout"]]
    useXDR <- options[["useXDR"]]
    nodeClass <- c("RichSOCKnode", if(useXDR) "SOCKnode" else "SOCK0node")
    cmd <- options[["cmd"]]

    if (verbose) {
      mdebugf("%sSystem call to launch all workers:", verbose_prefix)
      mdebugf("%s%s", verbose_prefix, cmd)
    }

    ## FIXME: Add argument, option, environment variable for this

    ## Start listening and start workers.
    if (verbose) mdebugf("%sStarting PSOCK main server", verbose_prefix)
    socket <- serverSocket(port = port)
    on.exit(if (!is.null(socket)) close(socket), add = TRUE)

    assert_system_is_supported()

    if (.Platform$OS.type == "windows") {
      for (ii in seq_along(cl)) {
        ## See parallel::newPSOCKnode() for the input = ""
        system(cmd, wait = FALSE, input = "")
      }
    } else {
      ## Asynchronous lists are defined by POSIX
      cmd <- paste(rep(cmd, times = length(cl)), collapse = " & ")
      system(cmd, wait = FALSE)
    }

    if (verbose) mdebugf("%sWorkers launched", verbose_prefix)

    ## Accept connections and send the first command as initial
    ## handshake.  The handshake makes TCP synchronization detect and
    ## err on half-opened connections, which arise during parallel setup
    ## of client-server connections (due to internal timeouts, limited
    ## length of the listen backlog queue, race in timing out on
    ## creating a connection and probably more).
    ##
    ## The handshake looks like a regular server command followed by
    ## client response, which is compatible with older versions of R.
    ready <- 0L
    pending <- list()
    on.exit({
      lapply(pending, FUN = function(x) close(x$con))
      cl <- NULL
    }, add = TRUE)

    if (verbose) mdebugf("%sWaiting for workers to connect back", verbose_prefix)

    t0 <- Sys.time()
    while (ready < length(cl)) {
      if (verbose) mdebugf(" - %s%d workers out of %d ready", verbose_prefix, ready, length(cl))

      cons <- lapply(pending, FUN = function(x) x$con)

      if (difftime(Sys.time(), t0, units="secs") > connectTimeout + 5) {
          ## The workers will give up after connectTimeout, so there is
          ## no point waiting for them much longer.
          failed <- length(cl) - ready
          stop(sprintf(ngettext(failed,
               "Cluster setup failed (connectTimeout=%.1f seconds). %d worker of %d failed to connect.",
               "Cluster setup failed (connectTimeout=%.1f seconds). %d of %d workers failed to connect."),
               connectTimeout + 5, failed, length(cl)))
      }
      a <- socketSelect(append(list(socket), cons), write = FALSE, timeout = connectTimeout)
      canAccept <- a[1]
      canReceive <- seq_along(pending)[a[-1]]

      if (canAccept) {
        attr(localhostHostname, "localhost") <- TRUE
        con <- socketAccept(socket = socket, blocking = TRUE, open = "a+b", timeout = timeout)
        options$rank <- ready
        options$pidfile <- NULL
        scon <- structure(
          list(con = con, host = localhostHostname, rank = ready),
          options = options,
          class = nodeClass
        )
        res <- tryCatch({
          sendCall(scon, eval, list(quote(Sys.getpid())))
        }, error = identity)
        pending <- append(pending, list(scon))
      }
      
      for (scon in pending[canReceive]) {
        pid <- tryCatch({
          recvResult(scon)
        }, error = identity)
        if (is.integer(pid)) {
          ready <- ready + 1L
          cl[[ready]] <- scon
        } else {
          close(scon$con)
        }
      }
      if (length(canReceive) > 0L) pending <- pending[-canReceive]
    } ## while()
    if (verbose) mdebugf(" - %s%d workers out of %d ready", verbose_prefix, ready, length(cl))
  } else if (setup_strategy == "sequential") {
    retryPort <- getOption2("parallelly.makeNodePSOCK.tries.port", "same")
    for (ii in seq_along(cl)) {
      if (verbose) {
        mdebugf("%sCreating node #%d of %d ...", verbose_prefix, ii, n)
        mdebugf("%s- setting up node", verbose_prefix)
      }

      options <- nodeOptions[[ii]]

      for (kk in 1:tries) {
        if (verbose) {
          mdebugf("%s- attempt #%d of %d", verbose_prefix, kk, tries)
        }
        node <- tryCatch({
          makeNode(options, verbose = verbose)
        }, error = identity)
        ## Success or an error that is not a connection error?
        if (!inherits(node, "PSOCKConnectionError")) break
        
        if (kk < tries) {
          if (verbose) {
            message(conditionMessage(node))
            ## Retry with a new random port?
            if (retryPort == "next") {
              options$port <- max(options$port + 1L, 65535L)
            } else if (retryPort == "available") {
              options$port <- freePort()
            }
            mdebugf("%s- waiting %g seconds before trying again",
                    verbose_prefix, delay)
          }
          Sys.sleep(delay)
        }  
      }
      if (inherits(node, "error")) {
        ex <- node
        if (inherits(node, "PSOCKConnectionError")) {
          if (verbose) {
            mdebugf("%s  Failed %d attempts with %g seconds delay",
                    verbose_prefix, tries, delay)
          }
          ex$message <- sprintf("%s\n * Number of attempts: %d (%gs delay)",
                                conditionMessage(ex), tries, delay)
        } else {
          ex$call <- sys.call()
        }
        stop(ex)
      }

      ## 'node' is NULL if dryrun = TRUE
      if (!is.null(node)) cl[[ii]] <- node
      stopifnot(length(cl) == n)
  
      if (verbose) {
        mdebugf("%sCreating node #%d of %d ... done", verbose_prefix, ii, n)
      }
    }
  }

  if (verbose) {
    mdebugf("%sLaunching of %d workers completed", verbose_prefix, n)
    mdebugf("%sNumber of nodes in cluster: %d", verbose_prefix, length(cl))
  }

  ## Cleanup
  try(close(socket), silent = TRUE)
  socket <- NULL

  ## Sanity check
  stopifnot(length(cl) == n)

  if (validate) {
    ## Attaching session information for each worker.  This is done to assert
    ## that we have a working cluster already here.  It will also collect
    ## useful information otherwise not available, e.g. the PID.
    if (verbose) {
      mdebugf("%sCollecting session information from %d workers", verbose_prefix, length(cl))
    }
    for (ii in seq_along(cl)) {
      cl[ii] <- add_cluster_session_info(cl[ii])
      if (verbose) mdebugf("%s - Worker #%d of %d", verbose_prefix, ii, length(cl))
    }
    stopifnot(length(cl) == n)
  }

  if (autoStop) {
    if (verbose) mdebugf("%sAdding automatic stop of cluster on garbage collection", verbose_prefix)
    cl <- autoStopCluster(cl)
    stopifnot(length(cl) == n)
  }

  if (verbose) {
    options(oopts)
    mdebugf("%smakeClusterPSOCK() ... done", verbose_prefix)
  }

  stopifnot(length(cl) == n)

  ## Success, remove automatic cleanup of nodes
  on.exit()

  cl
} ## makeClusterPSOCK()
