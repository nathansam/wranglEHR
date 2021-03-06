% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/extract.R
\name{process_item_timestamp}
\alias{process_item_timestamp}
\title{Process a specific concept_id}
\usage{
process_item_timestamp(dataitem, var_name, cadance, coalesce_rows)
}
\arguments{
\item{dataitem}{base table}

\item{var_name}{concept_id}

\item{cadance}{base time cadance}

\item{coalesce_rows}{summary function}

\item{start_time}{start_datetime to zero from}
}
\description{
Processes a concept_id retaining it's original timestamp
}
