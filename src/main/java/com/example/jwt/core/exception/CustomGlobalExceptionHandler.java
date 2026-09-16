package com.example.jwt.core.exception;

import io.github.resilience4j.circuitbreaker.CallNotPermittedException;
import java.time.LocalDate;
import java.util.Map;
import java.util.NoSuchElementException;
import java.util.stream.Collectors;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.client.HttpClientErrorException;
import org.springframework.web.client.HttpServerErrorException;
import org.springframework.web.client.ResourceAccessException;

@RestControllerAdvice
public class CustomGlobalExceptionHandler {

  @ExceptionHandler(MethodArgumentNotValidException.class)
  @ResponseStatus(value = HttpStatus.BAD_REQUEST)
  public ResponseError handleMethodArgumentNotValid(MethodArgumentNotValidException ex) {
    return new ResponseError()
        .setTimeStamp(LocalDate.now())
        .setErrors(ex.getBindingResult().getFieldErrors().stream().collect(
            Collectors.toMap(error -> error.getField(), error -> error.getDefaultMessage())))
        .build();
  }

  @ExceptionHandler(NoSuchElementException.class)
  @ResponseStatus(value = HttpStatus.NOT_FOUND)
  public ResponseError handleNoSuchElement(NoSuchElementException ex) {
    return new ResponseError().setTimeStamp(LocalDate.now())
        .setErrors(Map.of("id", ex.getMessage())).build();
  }

  @ExceptionHandler(HttpClientErrorException.class)
  public ResponseEntity<String> handleModuleServiceClientError(HttpClientErrorException ex) {
    return ResponseEntity.status(ex.getStatusCode()).contentType(MediaType.APPLICATION_JSON)
        .body(ex.getResponseBodyAsString());
  }

  @ExceptionHandler({ResourceAccessException.class, HttpServerErrorException.class,
      CallNotPermittedException.class})
  @ResponseStatus(value = HttpStatus.SERVICE_UNAVAILABLE)
  public ResponseError handleModuleServiceUnavailable(Exception ex) {
    return new ResponseError().setTimeStamp(LocalDate.now())
        .setErrors(Map.of("module", "module service unavailable")).build();
  }

}


