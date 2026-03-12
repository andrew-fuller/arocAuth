#' Authentication module UI
#'
#' Empty UI placeholder. The authentication module operates entirely server-side.
#'
#' @param id Module namespace ID.
#' @export
mod_authentication_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList()
}

#' Authentication module server
#'
#' Handles token-based authentication for AROC Shiny applications.
#' Validates a URL query string token against the DataVisToken table,
#' resolves hierarchical access (Org > Area > Facility) to HospitalIds,
#' and populates `user_settings$access_ids`.
#'
#' @param id Module namespace ID.
#' @param user_settings A reactiveValues object. Will have `username` and
#'   `access_ids` set upon successful authentication.
#' @param parent_session The parent Shiny session object.
#' @param con_ArocOnline Pool/DBI connection to AOS_ProdSG_ArocOnline
#'   (contains DataVisToken table).
#' @param con_OnlineReporting Pool/DBI connection to AOS_Prod_OnlineReporting
#'   (contains vw_orglist and _sp_DeleteShinyToken).
#' @param app_config Named list with:
#'   \describe{
#'     \item{usertype_flag_col}{Character. Flag column in
#'       `[web].[vw_arocAuth_Application_UserTypes]` for this app
#'       (e.g. `"flag_inp_dash"`, `"flag_inr_dash"`). Used to fetch allowed UserTypeIds.}
#'     \item{orglist_flag_col}{Character. Flag column in vw_orglist to filter by
#'       (e.g. "Flag_Inpatient", "Flag_Inreach")}
#'     \item{admin_token}{Character or NULL. Admin bypass token value.
#'       Recommended: use Sys.getenv("AROC_ADMIN_TOKEN")}
#'     \item{admin_hospital_ids}{Integer vector or NULL. HospitalIds granted to admin users.}
#'   }
#' @export
mod_authentication_server <- function(
  id,
  user_settings,
  parent_session,
  con_ArocOnline,
  con_OnlineReporting,
  app_config = list(
    usertype_flag_col  = NULL,
    orglist_flag_col   = "Flag_Inpatient",
    admin_token        = NULL,
    admin_hospital_ids = NULL
  )
) {
  shiny::moduleServer(id, function(input, output, session) {

    # Fetch allowed UserTypeIds from DB once at module initialisation
    allowed_user_types <- fetch_allowed_user_types(
      app_config$usertype_flag_col,
      con_ArocOnline
    )

    # Store token for use by deletion observer
    token_info <- shiny::reactiveValues(
      raw_token = NULL,
      is_admin = FALSE
    )

    ##* Validate token and populate user_settings --------------------------------
    shiny::observe({
      query <- shiny::parseQueryString(parent_session$clientData$url_search)
      message(
        "[arocAuth] Query: ",
        paste(names(query), query, sep = "=", collapse = ", ")
      )

      token_val <- as.character(query[["token"]])

      # Guard: no token
      if (is.null(token_val) || is.na(token_val) || length(token_val) == 0) {
        if (length(query) == 0) {
          message("[arocAuth] Authentication failed: No query string found.")
          shinyalert::shinyalert(
            "Login Failed: Token not found.",
            type = "error",
            showCancelButton = FALSE,
            showConfirmButton = FALSE,
            closeOnEsc = FALSE,
            closeOnClickOutside = FALSE
          )
        }
        return()
      }

      # Admin bypass
      admin_token <- app_config$admin_token
      if (!is.null(admin_token) &&
          nchar(admin_token) > 0 &&
          token_val == admin_token) {
        message("[arocAuth] Admin mode activated")
        token_info$is_admin <- TRUE
        user_settings$username <- "AROC_ADMIN"
        user_settings$access_ids <- as.integer(app_config$admin_hospital_ids)

        shinyWidgets::updateSwitchInput(
          session = parent_session,
          inputId = "user_loaded",
          value = TRUE
        )
        print("Admin User Authenticated via Query String")

        shinyalert::shinyalert(
          paste0("Welcome Admin: ", user_settings$username),
          type = "success",
          text = "Login successful",
          inputId = "intro",
          className = "intro_modal",
          showConfirmButton = FALSE,
          timer = 1500
        )
        return()
      }

      # Regular token validation
      message("[arocAuth] Starting validation for token...")
      tokenurl <- con_ArocOnline |>
        dplyr::tbl("DataVisToken") |>
        dplyr::collect()

      Token_clean <- gsub("=", "", tokenurl$Token)
      query_val <- as.character(query[[1]])

      uname <- dplyr::filter(
        tokenurl,
        query_val == gsub("=", "", tokenurl$Token)
      )

      if (nrow(uname) > 0) {
        user_settings$username <- uname$UserName[1]
        token_info$raw_token <- uname$Token[1]
        message(sprintf("[arocAuth] User: %s", uname$UserName[1]))
      }

      if (!(query_val %in% as.vector(Token_clean))) {
        message("[arocAuth] Authentication failed: Token is invalid.")
        shinyalert::shinyalert(
          "Login Failed",
          type = "error",
          showCancelButton = FALSE,
          showConfirmButton = FALSE,
          closeOnEsc = FALSE,
          closeOnClickOutside = FALSE
        )
        return()
      }

      # Token is valid — resolve access
      message("[arocAuth] Token is valid. Resolving access...")
      message("[arocAuth] Raw JsonData for user '", uname$UserName[1], "': ", uname$JsonData[1])

      result <- resolve_hospital_ids(
        json_data = uname$JsonData[1],
        allowed_user_types = allowed_user_types,
        con_reporting = con_OnlineReporting,
        flag_col = app_config$orglist_flag_col
      )

      if (!is.null(result$error) || length(result$hospital_ids) == 0) {
        err_msg <- result$error %||% "No valid access found"
        message(sprintf("[arocAuth] Access denied: %s", err_msg))
        shinyalert::shinyalert(
          title = "Access Denied",
          text = "You do not have the required access for this application.",
          type = "error",
          showCancelButton = FALSE,
          showConfirmButton = FALSE,
          closeOnEsc = FALSE,
          closeOnClickOutside = FALSE
        )
        return()
      }

      # Store resolved access
      user_settings$access_ids <- result$hospital_ids
      if (length(result$payer_ids) > 0) {
        user_settings$payer_ids <- result$payer_ids
      }

      message(sprintf(
        "[arocAuth] Resolved %d hospital ID(s): %s",
        length(result$hospital_ids),
        paste(result$hospital_ids, collapse = ", ")
      ))

      # Flip user_loaded switch
      shinyWidgets::updateSwitchInput(
        session = parent_session,
        inputId = "user_loaded",
        value = TRUE
      )
      print("User Authenticated")
      message("[arocAuth] Token successful for user: ", uname$UserName[1])

      shinyalert::shinyalert(
        paste0("Welcome: ", uname$UserName[1]),
        type = "success",
        text = "Login successful",
        inputId = "intro",
        className = "intro_modal",
        showConfirmButton = FALSE,
        timer = 1500
      )
    })

    ##* Clear token for the session -----------------------------------------------
    shiny::observe({
      if (token_info$is_admin) {
        message("[arocAuth] Admin mode - skipping token clearing")
        return()
      }

      raw_token <- token_info$raw_token
      if (is.null(raw_token)) return()

      message("[arocAuth] Starting token cleanup process...")
      delete_token(raw_token, con_OnlineReporting)
    })
  })
}
