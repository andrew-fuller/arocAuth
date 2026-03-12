#' Delete a single-use token from the database
#'
#' Calls the stored procedure `[dbo].[_sp_DeleteShinyToken]` to remove a
#' token after it has been used for authentication.
#'
#' @param token_raw Character. The raw token value from the DataVisToken table
#'   (may include trailing `=` characters).
#' @param con_reporting A pool/DBI connection to AOS_Prod_OnlineReporting
#'   (where the stored procedure lives).
#' @return Invisible NULL. Logs a message on success or warning on failure.
#' @export
delete_token <- function(token_raw, con_reporting) {
  tryCatch({
    sql <- paste0(
      "DECLARE @return_value int\n",
      "EXEC @return_value = [dbo].[_sp_DeleteShinyToken]\n",
      "@TokenToDelete = N'", token_raw, "'\n",
      "SELECT 'Return Value' = @return_value"
    )
    pool::dbExecute(con_reporting, sql)
    message("[arocAuth] Token deleted successfully.")
  }, error = function(e) {
    message("[arocAuth] Warning: Token deletion failed: ", e$message)
  })
  invisible(NULL)
}
