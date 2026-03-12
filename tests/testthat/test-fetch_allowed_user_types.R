# Mock connection that returns a predefined tibble for vw_arocAuth_Application_UserTypes
mock_aroc_con <- function(df) {
  con <- list()
  class(con) <- "mock_aroc_con"
  attr(con, "usertype_data") <- df
  con
}

# Override dplyr::tbl for mock class (in_schema returns same object)
tbl.mock_aroc_con <- function(src, from, ...) {
  attr(src, "usertype_data")
}
.S3method("tbl", "mock_aroc_con", tbl.mock_aroc_con)

# Sample data simulating vw_arocAuth_Application_UserTypes
sample_usertypes <- dplyr::tibble(
  UserTypeId    = c(126L, 200L, 300L, 400L),
  flag_inp_dash = c(1L,   1L,   0L,   0L),
  flag_inr_dash = c(0L,   0L,   1L,   0L),
  flag_org_dash = c(0L,   0L,   0L,   0L)
)

con <- mock_aroc_con(sample_usertypes)

# --- Test: returns correct UserTypeIds for flag_inp_dash ---
test_that("flag_inp_dash returns correct UserTypeIds", {
  result <- fetch_allowed_user_types("flag_inp_dash", con)

  expect_equal(sort(result), c(126L, 200L))
})

# --- Test: returns correct UserTypeIds for flag_inr_dash ---
test_that("flag_inr_dash returns correct UserTypeIds", {
  result <- fetch_allowed_user_types("flag_inr_dash", con)

  expect_equal(result, 300L)
})

# --- Test: stops when no rows match ---
test_that("stops with informative error when no UserTypes found", {
  expect_error(
    fetch_allowed_user_types("flag_org_dash", con),
    regexp = "No active UserTypes found for flag column 'flag_org_dash'"
  )
})

# --- Test: returns integer vector ---
test_that("result is always an integer vector", {
  result <- fetch_allowed_user_types("flag_inp_dash", con)

  expect_type(result, "integer")
})

# --- Test: handles single result correctly ---
test_that("single UserTypeId is returned as integer vector of length 1", {
  result <- fetch_allowed_user_types("flag_inr_dash", con)

  expect_length(result, 1L)
  expect_type(result, "integer")
})
