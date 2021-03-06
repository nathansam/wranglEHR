#' Extract & Reshape Data from EMAP
#'
#' This is the workhorse function that transcribes data from EMAP OPS from OMOP 
#' CDM 5.3.1 to a standard rectangular table with 1 column per dataitem and 1
#' row per time per patient.
#'
#' The time unit is user definable, and set by the "cadance" argument. The
#' default behaviour is to produce a table with 1 row per hour per patient. If
#' there are duplicates/conflicts (e.g more than 1 event for a given hour), then
#' the default behaviour is that only the first result for that hour is
#' returned. One can override this behvaiour by supplying a vector of summary
#' functions directly to the 'coalesce_rows' argument. This could also include
#' any custom function written by the end user, so long as it takes a vector of
#' length n, and returns a vector of length 1, of the original data type.
#'
#' Many events inside EMAP occur on a greater than hourly basis. Depending
#' upon the chosen analysis, you may which to increase the cadance. 0.5 for
#' example will produce a table with 1 row per 30 minutes per patient. Counter
#' to this, 24 would produce 1 row per 24 hours.
#'
#' Choose what variables you want to pull out wisely. This function is quite
#' efficient considering what it needs to do, but it can take a very long
#' time if extracting lots of data, and doing so repeatedly. It is a strong 
#' recomendation that you run your extraction on a small subset of patients
#' first and check that you are happy with the result, before moving to a larger
#' extraction.
#'
#' The current implementation is focussed on in-patients only. And as such, all
#' dataitems are referenced to the visit_start_datetime of the visit_occurrence.
#' Thus, observations and measurements recorded outside the boudaries of the
#' visit_occurrence are automatically removed. This is - at this stage -
#' intensional behaviour.
#'
#' @param connection a EMAP database connection
#' @param target_schema the target database schema
#' @param visit_occurrence_ids an integer vector of episode_ids or NULL. If NULL
#'   (the default) then all visits are extracted.
#' @param concept_names a vector of OMOP concept_ids to be extracted
#' @param relabel a character vector of names you want to relabel OMOP codes
#'   as, or NULL (the default) if you do not want to relabel. Given in the same
#'   order as \code{concept_names}
#' @param coalesce_rows a vector of summary functions that you want to summarise
#'   data that is contributed higher than your set cadance. Given in the same
#'   order as \code{concept_names}
#' @param chunk_size a chunking parameter to help speed up the function and
#'   manage memory constaints. The defaults work well for most desktop
#'   computers.
#' @param cadance a numerical scalar >= 0. Describes the base time unit to build
#'   each row, in divisions of an hour. For example: 1 = 1 hour, 0.5 = 30 mins,
#'   2 = 2 hourly. If cadance = 0, then the pricise datetime will be used to
#'   generate the time column. This is likely to generate a large table, so use
#'   cautiously.
#' @param timestamp logical scalar. Default FALSE. If TRUE the `time` column
#'   will present as a timestamp instead of time from admission. In this
#'   instance the `cadance` argument controls the roundings of the timestamp
#'   with 2 options: 1 = round to nearest hour, 2 = do not round.
#'
#' @return sparse tibble with hourly cadance as rows, and unique OMOP concepts
#'   as columns.
#' 
#' @export
#'
#' @importFrom purrr map imap
#' @importFrom lubridate now ymd_hms
#' @importFrom rlang inform abort .data
#' @importFrom dplyr first mutate select filter collect rename bind_rows n
#' @importFrom magrittr %>%
#' @importFrom tibble tibble
extract <- function(connection,
                    target_schema,
                    visit_occurrence_ids = NULL,
                    concept_names = NULL,
                    relabel = NULL,
                    coalesce_rows = dplyr::first,
                    chunk_size = 5000,
                    cadance = 1,
                    dttmstamp = FALSE) {

  starting <- now()
  tbls <- retrieve_tables(connection, target_schema)

  if (!(class(cadance) == "numeric" && cadance >= 0)) {
    rlang::abort(
      "`cadance` must be given as a numeric scalar >= 0")
  }
  
  params <- tibble::tibble(
    concept_names = as.integer(concept_names),
    short_names = relabel,
    func = c(coalesce_rows)
  )
  
  if (is.null(visit_occurrence_ids)) {
    vd_groups <- tbls[["visit_occurrence"]] %>%
      select(
        .data$visit_occurrence_id,
        .data$visit_start_datetime) %>%
      collect()
  } else {
    vd_groups <- tbls[["visit_occurrence"]] %>%
      filter(.data$visit_occurrence_id %in% visit_occurrence_ids) %>%
      select(
        .data$visit_occurrence_id,
        .data$visit_start_datetime) %>%
      collect()
  }
  
  vd_groups <- vd_groups %>%
    mutate(group = as.integer(seq(n()) / chunk_size)) %>%
    split(., .$group) %>%
    
    map(
      function(vd_group) {
        
        observations <- tbls[["observation"]] %>%
          filter(observation_concept_id %in% !!params$concept_names,
                 visit_occurrence_id %in% !!vd_group$visit_occurrence_id) %>%
          select(
            .data$person_id,
            .data$visit_occurrence_id,
            .data$observation_datetime,
            .data$observation_concept_id,
            .data$value_as_concept_id,
            .data$value_as_datetime,
            .data$value_as_number,
            .data$value_as_string
          ) %>%
          collect() %>%
          rename(
            datetime = observation_datetime,
            concept_id = observation_concept_id
          )
        
        if (nrow(observations) == 0) {
          no_observations <- TRUE
        } else {
          no_observations <- FALSE
        }
        
        measurements <- tbls[["measurement"]] %>%
          filter(measurement_concept_id %in% !!params$concept_names,
                 visit_occurrence_id %in% !!vd_group$visit_occurrence_id) %>%
          select(
            .data$person_id,
            .data$visit_occurrence_id,
            .data$measurement_datetime,
            .data$measurement_concept_id,
            .data$value_as_concept_id,
            .data$value_as_number
          ) %>%
          collect() %>%
          rename(
            datetime = measurement_datetime,
            concept_id = measurement_concept_id
          )
        
        if (nrow(measurements) == 0) {
          no_measurements <- TRUE
        } else {
          no_measurements <- FALSE
        }
        
        all_dat <- bind_rows(observations, measurements)
        
        vd_group$visit_occurrence_id %>%
          map(
            ~ process_all(
              visit_id = .x,
              dataitems = all_dat,
              visit_table = vd_group,
              cadance = cadance,
              coalesce_rows = params,
              dttmstamp = dttmstamp
            )
          ) %>%
          bind_rows()
      }) %>%
    bind_rows()
  
  
  for (i in seq_len(nrow(params))) {
    names(vd_groups) <- gsub(
      pattern = params$concept_names[i],
      replacement = params$short_names[i],
      x = names(vd_groups)
    )
  }

  elapsed_time <- signif(
    as.numeric(
      difftime(
        lubridate::now(), starting, units = "hour")), 2)
  inform(paste(elapsed_time, "hours to process"))
  
  if (requireNamespace("praise", quietly = TRUE)) {
    well_done <-
      praise::praise(
        "${EXCLAMATION}! How ${adjective} was that?!"
      )
    rlang::inform(well_done)
  }
  
  return(vd_groups)
}


#' Process all concepts within a group of visit_occurrences
#'
#' @param visit_id the visit_occurence_id to process
#' @param dataitems the table to process
#' @param visit_table a visit table constaining visit_start_datetime
#' @param cadance the base cadance
#' @param coalesce_rows a summary function
#' 
#' @importFrom dplyr filter select pull arrange full_join mutate rename
#' @importFrom purrr imap reduce
process_all <- function(visit_id,
                        dataitems,
                        visit_table,
                        cadance,
                        coalesce_rows,
                        dttmstamp) {
  
  visit_results <- dataitems %>%
    filter(visit_occurrence_id == visit_id)
  
  start_time <- visit_table %>%
    filter(visit_occurrence_id == visit_id) %>%
    select(visit_start_datetime) %>%
    pull()
  
  if (dttmstamp) {
    visit_results %>%
      arrange(concept_id) %>%
      split(., .$concept_id) %>%
      imap(
        ~ process_item_timestamp(
          dataitem = .x,
          var_name = .y,
          cadance = cadance,
          coalesce_rows = coalesce_rows)
      ) %>%
      reduce(
        full_join, by = "datetime",
        .init = tibble(datetime = ymd_hms())) %>%
      rename(time = datetime) %>%
      mutate(visit_occurrence_id = visit_id) %>%
      arrange(time)
  } else {
    visit_results %>%
      arrange(concept_id) %>%
      split(., .$concept_id) %>%
      imap(
        ~ process_item_difftime(
          dataitem = .x,
          var_name = .y,
          start_time = start_time,
          cadance = cadance,
          coalesce_rows = coalesce_rows)
      ) %>%
      reduce(
        full_join, by = "diff_time",
        .init = tibble(diff_time = as.numeric(NULL))) %>%
      rename(time = diff_time) %>%
      mutate(visit_occurrence_id = visit_id) %>%
      arrange(time)
  }
  

}

#' Process a specific concept_id
#' 
#' Process a concept_id in relationship to the time of hospital admission.
#'
#' @param dataitem base table
#' @param var_name concept_id
#' @param start_time start_datetime to zero from
#' @param cadance base time cadance
#' @param coalesce_rows summary function
#' 
#' @importFrom dplyr select filter pull mutate distinct rename group_by
#'   summarise_at vars
#' @importFrom rlang !! :=
#' @importFrom magrittr %>%
process_item_difftime <- function(dataitem,
                         var_name,
                         start_time,
                         cadance,
                         coalesce_rows) {
  
  stopifnot(!is.na(dataitem$datetime))
  
  prim_col <- mdata %>%
    filter(concept_id == var_name) %>%
    select(target) %>%
    pull()
  
  summary_func <- coalesce_rows %>%
    filter(concept_names == var_name) %>%
    select(func) %>%
    pull() %>%
    `[[`(1)
  
  tb_a <- dataitem %>%
    mutate(
      diff_time = as.numeric(difftime(datetime, start_time, units = "hours")))
  
  if (cadance > 0) {
    tb_a <- tb_a %>%
      mutate(diff_time = round_any(diff_time, cadance)) %>%
      group_by(diff_time) %>%
      summarise_at(vars(prim_col), summary_func)
  } else {
    tb_a <- tb_a %>%
      mutate(diff_time = round_any(diff_time, cadance)) %>%
      distinct(diff_time, .keep_all = TRUE)
  }
  
  tb_a %>%
    rename(!!var_name := prim_col) %>%
    select(diff_time, !!var_name)
}


#' Process a specific concept_id
#' 
#' Processes a concept_id retaining it's original timestamp
#'
#' @param dataitem base table
#' @param var_name concept_id
#' @param start_time start_datetime to zero from
#' @param cadance base time cadance
#' @param coalesce_rows summary function
#' 
#' @importFrom dplyr select filter pull mutate distinct rename group_by
#'   summarise_at vars
#' @importFrom rlang !! :=
#' @importFrom magrittr %>%
#' @importFrom lubridate round_date
process_item_timestamp <- function(dataitem,
                                  var_name,
                                  cadance,
                                  coalesce_rows) {
  
  stopifnot(cadance %in% c(0, 1))
  stopifnot(!is.na(dataitem$datetime))
  
  prim_col <- mdata %>%
    filter(concept_id == var_name) %>%
    select(target) %>%
    pull()
  
  summary_func <- coalesce_rows %>%
    filter(concept_names == var_name) %>%
    select(func) %>%
    pull() %>%
    `[[`(1)
  
  if (cadance == 1) {
    tb_a <- dataitem %>%
      mutate(datetime = round_date(datetime, unit = "hour")) %>%
      group_by(datetime) %>%
      summarise_at(vars(prim_col), summary_func)
  } else {
    tb_a <- dataitem %>%
      distinct(datetime, .keep_all = TRUE)
  }
  
  tb_a %>%
    rename(!!var_name := prim_col) %>%
    select(datetime, !!var_name)

}


#' Regularise an extracted table to a regular time cadance
#'
#' The \code{\link{extract}} function returns a non-sparse table (i.e.
#' rows/hours with no recorded information for a patient are not presented in
#' the table) This function serves to expand the table and fill missing rows
#' with NAs. This is useful when working with most time-series aware stats
#' packages that expect a regular cadance to the table.
#'
#' @param df a dense time series table produced from \code{\link{extract}}
#' @param cadance the cadance by which you want to expand the table
#'   (default = 1 hour)
#'   
#' @importFrom dplyr select bind_rows left_join
#' @importFrom purrr imap
#' @importFrom tibble tibble
#'
#' @return a sparse time series table
#' @export
regularise <- function(df, cadance = 1) {
  df %>%
    select(visit_occurrence_id, time) %>%
    split(., .$visit_occurrence_id) %>%
    imap(function(base_table, visit_id) {
      tibble(
        visit_occurrence_id = as.integer(visit_id),
        time = seq(
          min(base_table$time, 0),
          max(base_table$time, 0),
          by = cadance
        )
      )
    }) %>%
    bind_rows() %>%
    left_join(df, by = c("visit_occurrence_id", "time"))
}
