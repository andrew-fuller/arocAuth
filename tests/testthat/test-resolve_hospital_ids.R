# Mock connection that returns a predefined orglist tibble
# We use a local environment to simulate dplyr::tbl() on a connection
mock_con_reporting <- function(orglist_df) {
  con <- list()
  class(con) <- "mock_con"
  attr(con, "orglist") <- orglist_df
  con
}

# Override dplyr::tbl for our mock connection class
tbl.mock_con <- function(src, from, ...) {
  attr(src, "orglist")
}

# Register the S3 method so dplyr dispatch finds it
.S3method("tbl", "mock_con", tbl.mock_con)

# Sample orglist data simulating vw_orglist
sample_orglist <- dplyr::tibble(
  OrgId = c(17L, 17L, 17L, 24L, 25L, 25L),
  AreaId = c(46L, 46L, 61L, 47L, 113L, 113L),
  HospitalId = c(1L, 3L, 31L, 15L, 18L, 33L),
  Flag_Inpatient = c(1L, 1L, 1L, 1L, 1L, 1L),
  Flag_Inreach = c(0L, 0L, 0L, 0L, 1L, 1L)
)

con <- mock_con_reporting(sample_orglist)

# --- Test: Facility-level access ---
test_that("Facility-level access returns hospital_ids directly", {
  json <- jsonlite::toJSON(list(
    access = list(
      list(
        UserTypeId = 126L,
        role = list(
          access_scope = list(
            level = "Facility",
            entities = list(hospital_ids = list(1L, 3L))
          )
        )
      )
    )
  ), auto_unbox = TRUE)

  result <- resolve_hospital_ids(json, c(126L), con, "Flag_Inpatient")

  expect_null(result$error)
  expect_equal(sort(result$hospital_ids), c(1L, 3L))
})

# --- Test: Organisation-level access ---
test_that("Organisation-level access resolves to child HospitalIds", {
  json <- jsonlite::toJSON(list(
    access = list(
      list(
        UserTypeId = 126L,
        role = list(
          access_scope = list(
            level = "Organisation",
            entities = list(organisation_ids = list(17L))
          )
        )
      )
    )
  ), auto_unbox = TRUE)

  result <- resolve_hospital_ids(json, c(126L), con, "Flag_Inpatient")

  expect_null(result$error)
  # OrgId 17 has HospitalIds 1, 3, 31 (all Flag_Inpatient = 1)
  expect_equal(sort(result$hospital_ids), c(1L, 3L, 31L))
})

# --- Test: Area-level access ---
test_that("Area-level access resolves to child HospitalIds", {
  json <- jsonlite::toJSON(list(
    access = list(
      list(
        UserTypeId = 126L,
        role = list(
          access_scope = list(
            level = "Area",
            entities = list(area_ids = list(46L))
          )
        )
      )
    )
  ), auto_unbox = TRUE)

  result <- resolve_hospital_ids(json, c(126L), con, "Flag_Inpatient")

  expect_null(result$error)
  # AreaId 46 has HospitalIds 1, 3
  expect_equal(sort(result$hospital_ids), c(1L, 3L))
})

# --- Test: Non-matching UserType is ignored ---
test_that("Non-matching UserTypeId entries are ignored", {
  json <- jsonlite::toJSON(list(
    access = list(
      list(
        UserTypeId = 999L,
        role = list(
          access_scope = list(
            level = "Facility",
            entities = list(hospital_ids = list(1L, 3L))
          )
        )
      )
    )
  ), auto_unbox = TRUE)

  result <- resolve_hospital_ids(json, c(126L), con, "Flag_Inpatient")

  expect_equal(result$error, "No matching UserTypeIds found in token")
  expect_equal(length(result$hospital_ids), 0)
})

# --- Test: Multiple UserTypes, only matching ones contribute ---
test_that("Multiple UserTypes: only matching ones contribute IDs", {
  json <- jsonlite::toJSON(list(
    access = list(
      list(
        UserTypeId = 126L,
        role = list(
          access_scope = list(
            level = "Facility",
            entities = list(hospital_ids = list(1L))
          )
        )
      ),
      list(
        UserTypeId = 999L,
        role = list(
          access_scope = list(
            level = "Facility",
            entities = list(hospital_ids = list(99L, 100L))
          )
        )
      ),
      list(
        UserTypeId = 126L,
        role = list(
          access_scope = list(
            level = "Organisation",
            entities = list(organisation_ids = list(24L))
          )
        )
      )
    )
  ), auto_unbox = TRUE)

  result <- resolve_hospital_ids(json, c(126L), con, "Flag_Inpatient")

  expect_null(result$error)
  # UserType 126 Facility gives 1, UserType 126 Org 24 gives 15
  # UserType 999 is ignored
  expect_equal(sort(result$hospital_ids), c(1L, 15L))
  expect_false(99L %in% result$hospital_ids)
  expect_false(100L %in% result$hospital_ids)
})

# --- Test: Mixed Org + Facility levels combined ---
test_that("Mixed Org + Facility levels are combined and deduplicated", {
  json <- jsonlite::toJSON(list(
    access = list(
      list(
        UserTypeId = 126L,
        role = list(
          access_scope = list(
            level = "Facility",
            entities = list(hospital_ids = list(1L, 15L))
          )
        )
      ),
      list(
        UserTypeId = 126L,
        role = list(
          access_scope = list(
            level = "Organisation",
            entities = list(organisation_ids = list(17L))
          )
        )
      )
    )
  ), auto_unbox = TRUE)

  result <- resolve_hospital_ids(json, c(126L), con, "Flag_Inpatient")

  expect_null(result$error)
  # Facility: 1, 15. Org 17: 1, 3, 31. Union: 1, 3, 15, 31
  expect_equal(sort(result$hospital_ids), c(1L, 3L, 15L, 31L))
})

# --- Test: Flag filtering (Flag_Inreach) ---
test_that("Flag filtering respects the flag_col parameter", {
  json <- jsonlite::toJSON(list(
    access = list(
      list(
        UserTypeId = 126L,
        role = list(
          access_scope = list(
            level = "Organisation",
            entities = list(organisation_ids = list(25L))
          )
        )
      )
    )
  ), auto_unbox = TRUE)

  # With Flag_Inreach: OrgId 25 has HospitalIds 18, 33 with Flag_Inreach = 1
  result <- resolve_hospital_ids(json, c(126L), con, "Flag_Inreach")

  expect_null(result$error)
  expect_equal(sort(result$hospital_ids), c(18L, 33L))
})

# --- Test: Payer access stored separately ---
test_that("Payer-level access returns payer_ids separately", {
  json <- jsonlite::toJSON(list(
    access = list(
      list(
        UserTypeId = 126L,
        role = list(
          access_scope = list(
            level = "Payer",
            entities = list(payer_ids = list(501L, 502L))
          )
        )
      ),
      list(
        UserTypeId = 126L,
        role = list(
          access_scope = list(
            level = "Facility",
            entities = list(hospital_ids = list(1L))
          )
        )
      )
    )
  ), auto_unbox = TRUE)

  result <- resolve_hospital_ids(json, c(126L), con, "Flag_Inpatient")

  expect_null(result$error)
  expect_equal(result$hospital_ids, 1L)
  expect_equal(sort(result$payer_ids), c(501L, 502L))
})

# --- Test: Invalid JSON ---
test_that("Invalid JSON returns error", {
  result <- resolve_hospital_ids("not valid json{", c(126L), con, "Flag_Inpatient")

  expect_false(is.null(result$error))
  expect_equal(length(result$hospital_ids), 0)
})

# --- Test: Multiple allowed UserTypes ---
test_that("Multiple allowed_user_types are all processed", {
  json <- jsonlite::toJSON(list(
    access = list(
      list(
        UserTypeId = 126L,
        role = list(
          access_scope = list(
            level = "Facility",
            entities = list(hospital_ids = list(1L))
          )
        )
      ),
      list(
        UserTypeId = 200L,
        role = list(
          access_scope = list(
            level = "Facility",
            entities = list(hospital_ids = list(3L))
          )
        )
      )
    )
  ), auto_unbox = TRUE)

  result <- resolve_hospital_ids(json, c(126L, 200L), con, "Flag_Inpatient")

  expect_null(result$error)
  expect_equal(sort(result$hospital_ids), c(1L, 3L))
})
