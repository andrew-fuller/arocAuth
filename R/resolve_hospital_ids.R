#' Resolve hospital IDs from a DataVisToken JSON payload
#'
#' Parses the JSON access data from a DataVisToken entry and resolves
#' Organisation/Area-level access down to HospitalIds using the vw_orglist view.
#' Facility-level access is passed through directly. Payer-level access is
#' returned separately.
#'
#' @param json_data Character. Raw JSON string from DataVisToken.JsonData.
#' @param allowed_user_types Integer vector. UserTypeIds permitted for this app.
#' @param con_reporting A pool/DBI connection to AOS_Prod_OnlineReporting.
#' @param flag_col Character. Column name in vw_orglist to filter active
#'   facilities (e.g. "Flag_Inpatient" or "Flag_Inreach").
#' @return A list with elements:
#'   \describe{
#'     \item{hospital_ids}{Integer vector of resolved HospitalIds}
#'     \item{payer_ids}{Integer vector of payer IDs (if any)}
#'     \item{error}{NULL on success, or a character error message}
#'     \item{is_internal}{Logical. TRUE if any access entry has role$category == "I"}
#'   }
#' @export

# Internal helper: detect top-level category "I" (internal/admin)
detect_internal_category <- function(parsed) {
  identical(parsed$category, "I")
}

resolve_hospital_ids <- function(json_data,
                                 allowed_user_types,
                                 con_reporting,
                                 flag_col = "Flag_Inpatient") {
  tryCatch({
    parsed <- jsonlite::fromJSON(json_data, simplifyVector = FALSE)

    if (!("access" %in% names(parsed)) || !is.list(parsed$access)) {
      return(list(
        hospital_ids = integer(0),
        payer_ids = integer(0),
        error = "JSON missing 'access' array",
        is_internal = FALSE
      ))
    }

    # Log full payload before any filtering
    all_user_type_ids <- vapply(
      parsed$access,
      function(acc) as.integer(acc$UserTypeId %||% NA_integer_),
      integer(1)
    )
    message(sprintf(
      "[arocAuth] JSON payload contains %d access entr%s. UserTypeIds found: [%s]. Allowed: [%s]",
      length(parsed$access),
      if (length(parsed$access) == 1) "y" else "ies",
      paste(all_user_type_ids, collapse = ", "),
      paste(allowed_user_types, collapse = ", ")
    ))
    message("[arocAuth] Full JSON payload: ", json_data)

    # Detect internal (admin) category before UserType filtering
    is_internal <- detect_internal_category(parsed)
    if (is_internal) {
      message("[arocAuth] Internal category ('I') detected - marking as internal user")
    }

    # Filter to allowed UserTypes
    matched_entries <- Filter(
      function(acc) {
        !is.null(acc$UserTypeId) &&
          as.integer(acc$UserTypeId) %in% as.integer(allowed_user_types)
      },
      parsed$access
    )

    if (length(matched_entries) == 0) {
      return(list(
        hospital_ids = integer(0),
        payer_ids = integer(0),
        error = "No matching UserTypeIds found in token",
        is_internal = is_internal
      ))
    }

    # Determine which levels are present
    levels_present <- vapply(
      matched_entries,
      function(acc) acc$role$access_scope$level %||% "",
      character(1)
    )

    # Fetch vw_orglist only if hierarchy lookup is needed
    needs_lookup <- any(levels_present %in% c("Organisation", "Area"))
    orglist <- NULL

    if (needs_lookup) {
      orglist <- con_reporting |>
        dplyr::tbl("vw_orglist") |>
        dplyr::filter(.data[[flag_col]] == 1L) |>
        dplyr::select("OrgId", "AreaId", "HospitalId") |>
        dplyr::collect()
    }

    all_hospital_ids <- c()
    all_payer_ids <- c()

    for (acc in matched_entries) {
      level <- acc$role$access_scope$level
      entities <- acc$role$access_scope$entities

      if (is.null(level)) {
        message("[arocAuth] Skipping entry with NULL access level")
        next
      }

      resolved <- switch(level,
        "Facility" = {
          as.integer(unlist(entities$hospital_ids))
        },
        "Area" = {
          area_ids <- as.integer(unlist(entities$area_ids))
          if (is.null(orglist) || length(area_ids) == 0) {
            integer(0)
          } else {
            orglist |>
              dplyr::filter(.data$AreaId %in% area_ids) |>
              dplyr::pull("HospitalId") |>
              as.integer()
          }
        },
        "Organisation" = {
          org_ids <- as.integer(unlist(entities$organisation_ids))
          if (is.null(orglist) || length(org_ids) == 0) {
            integer(0)
          } else {
            orglist |>
              dplyr::filter(.data$OrgId %in% org_ids) |>
              dplyr::pull("HospitalId") |>
              as.integer()
          }
        },
        "Payer" = {
          payer_ids <- as.integer(unlist(entities$payer_ids))
          all_payer_ids <<- c(all_payer_ids, payer_ids)
          integer(0) # Payer does not resolve to HospitalIds
        },
        "Ward" = {
          message("[arocAuth] Ward-level access not yet supported, skipping")
          integer(0)
        },
        "Internal" = {
          message("[arocAuth] Internal-level access - no hospital IDs to resolve")
          integer(0)
        },
        {
          message(sprintf("[arocAuth] Unknown access level: %s, skipping", level))
          integer(0)
        }
      )

      all_hospital_ids <- c(all_hospital_ids, resolved)
    }

    all_hospital_ids <- unique(all_hospital_ids)
    all_payer_ids <- unique(all_payer_ids)

    if (length(all_hospital_ids) == 0 && length(all_payer_ids) == 0) {
      return(list(
        hospital_ids = integer(0),
        payer_ids = integer(0),
        error = "Resolved to zero hospital IDs",
        is_internal = is_internal
      ))
    }

    list(
      hospital_ids = all_hospital_ids,
      payer_ids = all_payer_ids,
      error = NULL,
      is_internal = is_internal
    )
  }, error = function(e) {
    list(
      hospital_ids = integer(0),
      payer_ids = integer(0),
      error = paste("Resolution error:", e$message),
      is_internal = FALSE
    )
  })
}
