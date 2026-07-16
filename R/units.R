# pH is a dimensionless *identity* in this package's unit engine (CONTRACT
# A26). udunits DOES recognise a native `pH` unit, but treats it as a
# logarithmic unit that is NOT convertible to the dimensionless unit `1`
# (`units::ud_are_convertible("pH", "1")` is FALSE) - and it doesn't know
# "pH Unit"/"pH_Units" at all. Rather than let udunits' native (and
# unhelpfully non-convertible) `pH` leak through, every one of these three
# spellings is intercepted before it ever reaches udunits and treated as an
# alias for the dimensionless unit `"1"`.
.unitless_aliases <- c("pH", "pH Unit", "pH_Units")

#' Canonical form of a unit string for internal comparisons
#'
#' Collapses any of `.unitless_aliases` to the dimensionless udunits symbol
#' `"1"`; everything else passes through unchanged.
#'
#' @param unit character vector.
#' @return character vector, same length.
#' @keywords internal
.canonical_unit <- function(unit) {
  ifelse(unit %in% .unitless_aliases, "1", unit)
}

#' Is a string a valid, recognised unit?
#'
#' `pH`, `pH Unit` and `pH_Units` are always valid (registered as dimensionless
#' unitless aliases; CONTRACT A26). Everything else is checked against the
#' udunits2 database via `units::as_units()`.
#'
#' @param unit character vector of unit strings to check.
#' @return logical vector, same length as `unit`. `NA` input yields `NA`.
#' @keywords internal
#' @noRd
is_valid_unit <- function(unit) {
  checkmate::assert_character(unit, min.len = 0)
  vapply(
    unit,
    function(u) {
      if (is.na(u)) {
        return(NA)
      }
      if (u %in% .unitless_aliases) {
        return(TRUE)
      }
      isTRUE(tryCatch(
        {
          units::as_units(u)
          TRUE
        },
        error = function(e) FALSE
      ))
    },
    logical(1),
    USE.NAMES = FALSE
  )
}

#' Are two units dimensionally compatible (convertible)?
#'
#' `pH`/`pH Unit`/`pH_Units` are compatible with each other (and only each
#' other) as dimensionless unitless aliases (CONTRACT A26); they are never
#' compatible with a "real" physical unit such as `mg/L`.
#'
#' @param units_a,units_b character vectors of unit strings, recycled to a
#'   common length.
#' @return logical vector. `NA` if either input unit is `NA`.
#' @keywords internal
#' @noRd
are_compatible_units <- function(units_a, units_b) {
  checkmate::assert_character(units_a, min.len = 1)
  checkmate::assert_character(units_b, min.len = 1)
  n <- max(length(units_a), length(units_b))
  units_a <- rep_len(units_a, n)
  units_b <- rep_len(units_b, n)

  vapply(
    seq_len(n),
    function(i) {
      a <- units_a[[i]]
      b <- units_b[[i]]
      if (is.na(a) || is.na(b)) {
        return(NA)
      }
      a_alias <- a %in% .unitless_aliases
      b_alias <- b %in% .unitless_aliases
      if (a_alias || b_alias) {
        return(a_alias && b_alias)
      }
      isTRUE(tryCatch(units::ud_are_convertible(a, b), error = function(e) FALSE))
    },
    logical(1)
  )
}

#' Recycle a units vector to a target length, erroring on a bad length
#' @keywords internal
.recycle_units <- function(units_x, n, arg_name) {
  checkmate::assert_character(units_x, min.len = 1)
  if (length(units_x) == n) {
    return(units_x)
  }
  if (length(units_x) == 1) {
    return(rep(units_x, n))
  }
  cli::cli_abort(
    "{.arg {arg_name}} must have length 1 or {n} (length of {.arg value}), not {length(units_x)}.",
    class = c("sampletidy_units_error", "sampletidy_error")
  )
}

#' Convert values between units
#'
#' Pure, vectorised unit conversion. Every element of `value` is converted
#' independently from `units_from[i]` to `units_to[i]` (both recycled to
#' `length(value)`), using `units::set_units(mode = "standard")` internally,
#' and the result is returned in the original input order.
#'
#' NA semantics:
#' - both `units_from[i]` and `units_to[i]` `NA` -> value unchanged.
#' - `units_from[i]` `NA` (regardless of `units_to[i]`) -> value unchanged.
#' - `units_to[i]` `NA` while `units_from[i]` is set -> aborts.
#'
#' Identical `units_from[i]`/`units_to[i]` (after resolving `pH`/`pH Unit`/
#' `pH_Units` aliases to the same dimensionless group) short-circuits to the
#' original value with no pass through udunits, so no floating-point noise is
#' introduced by an unnecessary round trip.
#'
#' This function does not resolve analyte/method lookups - callers must
#' already know the unit strings on both sides. Unlike the ported
#' `WEM.data::unify_value()`, an invalid unit aborts (naming the offending
#' string) rather than prompting interactively; callers (the reconciler)
#' catch the error and queue it for review.
#'
#' @param value numeric vector of values to convert.
#' @param units_from,units_to character vectors of unit strings, each
#'   recycled to `length(value)`.
#' @return numeric vector, same length as `value`, in the original order.
#' @keywords internal
#' @noRd
unify_value <- function(value, units_from, units_to) {
  checkmate::assert_numeric(value, min.len = 0)
  n <- length(value)
  units_from <- .recycle_units(units_from, n, "units_from")
  units_to <- .recycle_units(units_to, n, "units_to")

  result <- value

  from_na <- is.na(units_from)
  to_na <- is.na(units_to)

  # units_to missing while units_from is set -> abort (never silently
  # unchanged, since the caller clearly intended a conversion).
  bad <- !from_na & to_na
  if (any(bad)) {
    bad_idx <- which(bad)
    bad_from <- unique(units_from[bad_idx])
    cli::cli_abort(
      c(
        "{.arg units_to} is missing at position(s) {bad_idx} while {.arg units_from} is set.",
        "i" = "{.arg units_from} value(s): {.val {bad_from}}"
      ),
      class = c("sampletidy_units_error", "sampletidy_error")
    )
  }

  # Both NA, or units_from NA -> value passes through unchanged.
  needs_conversion <- !from_na & !to_na

  canon_from <- .canonical_unit(units_from)
  canon_to <- .canonical_unit(units_to)

  identical_units <- needs_conversion & (canon_from == canon_to)
  to_convert <- needs_conversion & !identical_units

  if (any(to_convert)) {
    idx <- which(to_convert)

    offending <- unique(c(canon_from[idx], canon_to[idx]))
    valid <- is_valid_unit(offending)
    if (any(!valid)) {
      cli::cli_abort(
        "Invalid unit{?s}: {.val {offending[!valid]}}.",
        class = c("sampletidy_units_error", "sampletidy_error")
      )
    }

    converted <- tryCatch(
      {
        out <- numeric(length(idx))
        pair_key <- paste(canon_from[idx], canon_to[idx], sep = "\u2192")
        groups <- split(idx, pair_key)
        for (g in groups) {
          v <- units::set_units(value[g], canon_from[g][[1]], mode = "standard")
          v <- units::set_units(v, canon_to[g][[1]], mode = "standard")
          out[match(g, idx)] <- units::drop_units(v)
        }
        out
      },
      error = function(e) {
        cli::cli_abort(
          "Could not convert {.val {unique(canon_from[idx])}} to {.val {unique(canon_to[idx])}}: {conditionMessage(e)}",
          class = c("sampletidy_units_error", "sampletidy_error"),
          parent = e
        )
      }
    )
    result[idx] <- converted
  }

  result
}
