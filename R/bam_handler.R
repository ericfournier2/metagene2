#' A class to manage BAM files.
#'
#' This class will allow to load, convert and normalize alignments and regions
#' files/data.
#'
#' @section Constructor:
#' \describe{
#'    \item{}{\code{bh <- Bam_Handler$new(bam_files, cores = SerialParam())}}
#'    \item{bam_files}{A \code{vector} of BAM filenames. The BAM files must be
#'                    indexed. i.e.: if a file is named file.bam, there must
#'                    be a file named file.bam.bai or file.bai in the same 
#'                    directory.}
#'    \item{cores}{The number of cores available to parallelize the analysis.
#'                Either a positive integer or a \code{BiocParallelParam}.
#'                Default: \code{SerialParam()}.}
#'    \item{paired_end}{If \code{TRUE}, metagene will deal with paired-end 
#'                data. If \code{FALSE}, single-end data are expected}
#' }
#'
#' \code{Bam_Handler$new} returns a \code{Bam_Handler} object that contains
#' and manages BAM files. Coverage related information as alignment count can
#' be obtain by using this object.
#'
#' @return
#' \code{Bam_Handler$new} returns a \code{Bam_Handler} object which contains
#' coverage related information for every BAM files.
#'
#' @section Methods:
#' \describe{
#'    \item{}{\code{bh$get_aligned_count(bam_file)}}
#'    \item{bam_file}{The name of the BAM file.}
#' }
#' \describe{
#'    \item{}{\code{bg$get_bam_name(bam_file)}}
#'    \item{bam_file}{The name of the BAM file.}
#' }
#' \describe{
#'    \item{}{\code{bh$get_rpm_coefficient(bam_file)}}
#'    \item{bam_file}{The name of the BAM file.}
#' }
#' \describe{
#'    \item{}{\code{bh$index_bam_files(bam_files)}}
#'    \item{bam_files}{A \code{vector} of BAM filenames.}
#' }
#' \describe{
#'    \item{}{\code{bh$get_bam_files()}}
#' }
#' \describe{
#'    \item{}{\code{bh$get_coverage(bam_file, regions)
#'                                force_seqlevels = FALSE)}}
#'    \item{bam_file}{The name of the BAM file.}
#'    \item{regions}{A not empty \code{GRanges} object.}
#'    \item{force_seqlevels}{If \code{TRUE}, Remove regions that are not found
#'                    in bam file header. Default: \code{FALSE}. TRUE and FALSE
#'                    respectively correspond to pruning.mode = "coarse" 
#'                    and "error" in ?seqinfo.}
#' }
#' \describe{
#'    \item{}{\code{bh$get_normalized_coverage(bam_file, regions)
#'                                force_seqlevels = FALSE)}}
#'    \item{bam_file}{The name of the BAM file.}
#'    \item{regions}{A not empty \code{GRanges} object.}
#'    \item{force_seqlevels}{If \code{TRUE}, Remove regions that are not found
#'                    in bam file header. Default: \code{FALSE}. TRUE and FALSE
#'                    respectively correspond to pruning.mode = "coarse" 
#'                    and "error" in ?seqinfo.}
#' }
#' \describe{
#'    \item{}{\code{bh$get_noise_ratio(chip_bam_file, input_bam_file)}}
#'    \item{chip_bam_file}{The path to the chip bam file.}
#'    \item{input_bam_file}{The path to the input (control) bam file.}
#' }
#' @examples
#' bam_file <- get_demo_bam_files()[1]
#' bh <- metagene:::Bam_Handler$new(bam_files = bam_file)
#' bh$get_aligned_count(bam_file)
#'
#' @importFrom R6 R6Class
#' @export
#' @format A BAM manager

Bam_Handler <- R6Class("Bam_Handler",
    public = list(
        parameters = list(),
        initialize = function(bam_files, cores = SerialParam(), 
                              paired_end = FALSE, strand_specific=FALSE,
                              paired_end_strand_mode=2, extend_reads=0) {
            # Check prerequisites
            # bam_files must be a vector of BAM filenames
            if (!is.vector(bam_files, "character")) {
                stop("bam_files must be a vector of BAM filenames")
            }

            # All BAM files must exist
            if (!all(sapply(bam_files, file.exists))) {
                stop("At least one BAM file does not exist")
            }

            # All BAM files must be indexed
            if (any(is.na(sapply(bam_files, private$get_bam_index_filename)))) {
                stop("All BAM files must be indexed")
            }

            # All BAM names must be unique
            if (is.null(names(bam_files))) {
                bam_names <- tools::file_path_sans_ext(basename(bam_files))
            } else {
                bam_names = names(bam_files)
            }
            
            if (length(bam_names) != length(unique(bam_names))) {
                stop("All BAM names must be unique")
            }
            names(bam_files) = bam_names
            
            # Core must be a positive integer or a BiocParallelParam instance
            isBiocParallel = is(cores, "BiocParallelParam")
            isInteger = ((is.numeric(cores) || is.integer(cores)) &&
                            cores > 0 &&as.integer(cores) == cores)
            if (!isBiocParallel && !isInteger) {
                stop(paste0("cores must be a positive numeric or ",
                    "BiocParallelParam instance"))
            }

            # paired_end must be logical
            if (!is.logical(paired_end)) {
                stop("paired_end argument must be logical")
            }    
            
            # Initialize the Bam_Handler object
            private$parallel_job <- Parallel_Job$new(cores)
            self$parameters[["cores"]] <- private$parallel_job$get_core_count()
            self$parameters[["paired_end"]] <- paired_end
            self$parameters[["strand_specific"]] <- strand_specific
            self$parameters[["paired_end_strand_mode"]] <- paired_end_strand_mode
            self$parameters[["extend_reads"]] <- extend_reads
            
            private$bam_files <- data.frame(bam = bam_files,
                                            stringsAsFactors = FALSE)

            private$bam_files[["aligned_count"]] <-
                sapply(private$bam_files[["bam"]], private$get_file_count)
                
            # Check the seqnames
            get_seqnames <- function(bam_file) {
                bam_file <- Rsamtools::BamFile(bam_file)
                GenomeInfoDb::seqnames(GenomeInfoDb::seqinfo(bam_file))
            }
            bam_seqnames <- lapply(private$bam_files$bam, get_seqnames)
            all_seqnames <- unlist(bam_seqnames)
            if (!all(table(all_seqnames) == length(bam_seqnames))) {
                msg <- paste0("\n\nSome bam files have discrepancies in their seqnames.\n\n",
                              "This could be caused by chromosome names",
                              " present only in a subset of the bam ",
                              "files (i.e.: chrY in some bam files, but ",
                              "absent in others.\n\n",
                              "This could also be caused by ",
                              "discrepancies in the seqlevels style",
                              " (i.e.: UCSC:chr1 versus NCBI:1)\n\n")
                warning(msg)
            }
        },
        get_bam_name = function(bam_file) {
            bam <- private$bam_files[["bam"]]
            row_names <- rownames(private$bam_files)
            bam_name <- basename(gsub(".bam$", "", bam_file))
            if (bam_file %in% bam) {
                i <- bam == bam_file
                stopifnot(sum(i) == 1)
                row_names[i]
            } else if (basename(bam_file) %in% bam) {
                i <- bam == tools::file_path_sans_ext(bam_file)
                stopifnot(sum(i) == 1)
                row_names[i]
            } else if (bam_name %in% row_names) {
                bam_name
            } else {
                NULL
            }
        },
        get_aligned_count = function(bam_file) {
            # Check prerequisites
            # The bam file must be in the list of bam files used for
            # initialization
            bam_name <- private$check_bam_file(bam_file)
            i <- rownames(private$bam_files) == bam_name
            private$bam_files[["aligned_count"]][i]
        },
        get_rpm_coefficient = function(bam_file) {
            return(self$get_aligned_count(bam_file) / 1000000)
        },
        index_bam_files = function(bam_files) {
            sapply(bam_files, private$index_bam_file)
        },
        get_bam_files = function() {
            private$bam_files
        },
        get_coverage = function(bam_file, regions, force_seqlevels = FALSE, simplify=TRUE) {
            private$generic_get_coverage(bam_file, regions, force_seqlevels, simplify=simplify)
        },
        get_normalized_coverage = function(bam_file, regions,
                            force_seqlevels = FALSE, simplify=TRUE) {
            count <- self$get_aligned_count(bam_file)
            private$generic_get_coverage(bam_file, regions, force_seqlevels, count, simplify=simplify)
        },
        get_noise_ratio = function(chip_bam_names, input_bam_names) {
            lapply(c(chip_bam_names, input_bam_names), private$check_bam_file)

            chip.pos <- private$read_bam_files(chip_bam_names)
            input.pos <- private$read_bam_files(input_bam_names)
            DBChIP:::NCIS.internal(chip.pos, input.pos)$est
        }
    ),
    private = list(
        bam_files = data.frame(),
        parallel_job = '',
        check_bam_file = function(bam_file) {
            if (!is.character(bam_file)) {
                stop("bam_file class should be character")
            }
            if (length(bam_file) != 1) {
                stop("bam_file should contain exactly 1 bam filename")
            }
            bam_name <- self$get_bam_name(bam_file)
            if (is.null(bam_name)) {
                stop(paste0("Bam file ", bam_file, " not found."))
            }
            invisible(bam_name)
        },
        check_bam_levels = function(bam_file, regions, force_seqlevels) {
            bam_levels <- GenomeInfoDb::seqlevels(Rsamtools::BamFile(bam_file))
            if (!all(unique(GenomeInfoDb::seqlevels(regions)) %in% bam_levels))
            {
                if (force_seqlevels == FALSE) {
                    stop("Some seqlevels of regions are absent in bam_file")
                } else { #force_seqlevels = TRUE
                    #force_seqlevels is used here but the user interface 
                    #continue to use force_seqlevels an boolean mode
                    GenomeInfoDb::seqlevels(regions, 
                                    pruning.mode = 'coarse') <- bam_levels
                    if (length(regions) == 0) {
                        stop(paste("No seqlevels matching between ",
                                        "regions and bam file", sep=''))
                    }
                }
            }
            regions
        },
        check_bam_length = function(bam_file, regions) {
            bam_infos <- GenomeInfoDb::seqinfo(Rsamtools::BamFile(bam_file))
            grl <- split(regions, as.character(seqnames(regions)))
            gr_max <- vapply(grl, function(x) max(end(x)), numeric(1))
            i <- match(names(gr_max), seqnames(bam_infos))
            if (!all(seqlengths(bam_infos)[i] >= gr_max)) {
                stop("Some regions are outside max chromosome length")
            }
            regions
        },
        get_bam_index_filename = function(bam_file) {
            # Look for a file where bai is appended (.bam.bai)
            bai_suffix_filename = paste(bam_file, ".bai", sep="")
            if(file.exists(bai_suffix_filename)) {
                return(bai_suffix_filename)
            } else {
                # Look for a file where bai replaces bam (.bai)
                bam_is_bai_filename = gsub("\\.bam$", ".bai", bam_file)
                if(file.exists(bam_is_bai_filename)) {
                    return(bam_is_bai_filename)
                }
            }
            # No index file found, return NA.
            return(NA)
        },
        index_bam_file = function(bam_file) {
            if (is.na(private$get_bam_index_filename(bam_file))) {
                # If there is no index file, we sort and index the current bam
                # file
                # TODO: we need to check if the sorted file was previously
                # produced before doing the costly sort operation
                sorted_bam_file <- paste0(basename(bam_files), ".sorted")
                sortBam(bam_file, sorted_bam_file)
                sorted_bam_file <- paste0(sorted_bam_file, ".bam")
                indexBam(sorted_bam_file)
                bam_file <- sorted_bam_file
            }
            bam_file
        },
        read_bam_files = function(bam_files) {
            if (length(bam_files) > 1) {
                pos <- lapply(bam_files, read.BAM)
                names <- unique(unlist(lapply(pos, names), use.names = FALSE))
                res <- list()
                fetch_pos <- function(name) {
                    res[["-"]] <- lapply(pos, function(x) x[[name]][["-"]])
                    res[["+"]] <- lapply(pos, function(x) x[[name]][["+"]])
                    res[["-"]] <- do.call("c", res[["-"]])
                    res[["+"]] <- do.call("c", res[["+"]])
                    res[["-"]] <- res[["-"]][order(res[["-"]])]
                    res[["+"]] <- res[["+"]][order(res[["+"]])]
                    res
                }
                result <- lapply(names, fetch_pos)
                names(result) <- names
                result
            } else {
                read.BAM(bam_files)
            }
        },
        get_file_count = function(bam_file) {
            sum(Rsamtools::idxstatsBam(bam_file)$mapped)
        },
        prepare_regions = function(regions, bam_file, force_seqlevels) {
            # The regions must be a GRanges object
            if (class(regions) != "GRanges") {
                stop("Parameter regions must be a GRanges object.")
            }

            # The seqlevels of regions must all be present in bam_file
            regions <- private$check_bam_levels(bam_file, regions,
                            force_seqlevels = force_seqlevels)
            to_remove <- seqlevels(regions)[!(seqlevels(regions) %in%
                                            unique(seqnames(regions)))]
            regions <- dropSeqlevels(regions, to_remove)

            # The regions must not be empty
            if (length(regions) == 0) {
                stop("Parameter regions must not be an empty GRanges object")
            }

            # The seqlevels of regions must all be present in bam_file
            regions <- private$check_bam_levels(bam_file, regions,
                            force_seqlevels = force_seqlevels)

            # The seqlengths of regions must be smaller or eqal to those in
            # bam_file
            regions <- private$check_bam_length(bam_file, regions)

            # The regions must not be overlapping
            reduce(regions)
        },
        read_alignments = function(regions, bam_file, strand=NULL, 
                                   paired_end=FALSE, paired_end_strand_mode=2) {
            # Subset regions according to strand and determine the value
            # passed to scanBamFlag's isMinusStrand.
            if(!is.null(strand)) {
                regions = regions[strand(regions)==strand]
                strand_flag = c('+'=FALSE, '-'=TRUE, '*'=NA)[strand]
                strand_mode = 0
            } else {
                strand_flag = NA
                strand_mode = paired_end_strand_mode
            }
            
            if(length(regions) > 0) {
                # Build a ScanBamParam object using the correct regions
                # and the correct strand.
                scan_flag = Rsamtools:::scanBamFlag(isMinusStrand=strand_flag)
                param <- Rsamtools:::ScanBamParam(which=reduce(regions), flag=scan_flag)
                
                # Read alignments.
                if(!paired_end) {
                    alignment <- GenomicAlignments:::readGAlignments(bam_file, param=param)
                } else {
                    alignment <- GenomicAlignments:::readGAlignmentPairs(bam_file, param=param,
                                                                         strandMode=strand_mode)
                }
            } else {
                # If there are no regions, build an empty alignment object.
                # By default, passing an empty region set to 
                # GenomicAlignments:::readGAlignments returns all alignments.
                alignment <- GenomicAlignments::GAlignments()
            }            
                
            return(alignment)
        },
        extract_coverage_by_regions = function(regions, bam_file, count=NULL, 
                                               paired_end = FALSE,
                                               strand_specific=FALSE,
                                               paired_end_strand_mode=2, extend=0){
            if(extend > 0) {
                start(regions) = pmax(start(regions)-extend, 1)
                end(regions) = end(regions)+extend
            }
                                               
            if(!strand_specific) {
                alignment = list('+'=NULL, '-'=NULL,
                                 '*'=private$read_alignments(regions, bam_file, paired_end=paired_end,
                                                             paired_end_strand_mode=paired_end_strand_mode))
            } else {
                # Read regions on each strand separately.
                alignment = list('+'=private$read_alignments(regions, bam_file, '+',
                                                             paired_end=paired_end,
                                                             paired_end_strand_mode=paired_end_strand_mode),
                                 '-'=private$read_alignments(regions, bam_file, '-',
                                                             paired_end=paired_end,
                                                             paired_end_strand_mode=paired_end_strand_mode),
                                 '*'=private$read_alignments(regions, bam_file, '*',
                                                             paired_end=paired_end,
                                                             paired_end_strand_mode=paired_end_strand_mode))
            }
                
            if (!is.null(count)) {
                weight <- 1 / (count / 1000000)
            } else {
                weight <- 1
            }
            
            weighted_coverage <- function(x, extend) {
                if(is.null(x)) {
                    return(x)
                } else { 
                    if(extend==0) {
                        return(GenomicAlignments::coverage(x) * weight)
                    } else {
                        return(GenomicRanges::coverage(GenomicRanges::resize(as(x, "GRanges"), width=extend, fix="start")) * weight)
                    }
                }
            }
            return(lapply(alignment, weighted_coverage, extend=extend))
        },
        generic_get_coverage = function(bam_file, regions, force_seqlevels = FALSE, count=NULL, simplify=TRUE) {
            private$check_bam_file(bam_file)
            regions <- private$prepare_regions(regions, bam_file,
                                                force_seqlevels)
            coverages = private$extract_coverage_by_regions(regions, bam_file, count,
                                paired_end = self$parameters[['paired_end']],
                                strand_specific = self$parameters[['strand_specific']],
                                paired_end_strand_mode = self$parameters[['paired_end_strand_mode']],
                                extend=self$parameters[['extend_reads']])
                                
            if(simplify && !self$parameters[["strand_specific"]]) {
                return(coverages[["*"]])
            } else {
                return(coverages)
            }                                
        }
    )
)
