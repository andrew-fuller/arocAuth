#' Fetch allowed UserTypeIds for an application from the database
#'
#' Queries `[web].[vw_arocAuth_Application_UserTypes]` in AOS_ProdSG_ArocOnline
#' and returns the UserTypeIds where the specified application flag column equals 1.
#'
#' @param usertype_flag_col Character. The flag column in
#'   `vw_arocAuth_Application_UserTypes` corresponding to the target application
#'   (e.g. `"flag_inp_dash"`, `"flag_inr_dash"`).
#' @param con_aroc_online A pool/DBI connection to AOS_ProdSG_ArocOnline.
#' @return Integer vector of allowed UserTypeIds. Stops with an error if none found.
#' @export
fetch_allowed_user_types <- function(usertype_flag_col, con_aroc_online) {
  rows <- con_aroc_online |>
    dplyr::tbl(dbplyr::in_schema("web", "vw_arocAuth_Application_UserTypes")) |>
    dplyr::filter(.data[[usertype_flag_col]] == 1L) |>
    dplyr::select("UserTypeId") |>
    dplyr::collect()

  if (nrow(rows) == 0) {
    stop(sprintf(
      "[arocAuth] No active UserTypes found for flag column '%s'. Check vw_arocAuth_Application_UserTypes.",
      usertype_flag_col
    ))
  }

  message(sprintf(
    "[arocAuth] Fetched %d allowed UserTypeId(s) for '%s': %s",
    nrow(rows),
    usertype_flag_col,
    paste(rows$UserTypeId, collapse = ", ")
  ))

  as.integer(rows$UserTypeId)
}
