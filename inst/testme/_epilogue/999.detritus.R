## Look for detritus files
testme <- as.environment("testme")
message(sprintf("Looking for detritus files generated by test %s:", sQuote(testme[["name"]])))
path <- dirname(tempdir())

if (basename(path) == "working_dir") {
  files <- dir(pattern = "^Rscript", path = path, all.files = TRUE, full.names = TRUE)
  message(sprintf("Detritus 'Rscript*' files: [n=%d]", length(files)))
  print(files)
  
  if (length(files) > 0L) {
    ## Remove detritus files produced by this test script, so that
    ## other test scripts will not fail because of these files.
    unlink(files)

    msg <- sprintf("Detected 'Rscript*' files: [n=%d] %s", length(files), paste(sQuote(basename(files)), collapse = ", "))

    ## Are detritus files files expected by design on MS Windows?
    ## If so, produce a warning, otherwise an error
    if ("detritus-files" %in% testme[["tags"]] &&
        .Platform[["OS.type"]] == "windows") {
      warning(msg, immediate. = TRUE)
    } else {
      stop(msg)
    }
  }
} else {
  message(sprintf("Skipping, because path appears not to be an 'R CMD check' folder: %s", sQuote(path)))
}
