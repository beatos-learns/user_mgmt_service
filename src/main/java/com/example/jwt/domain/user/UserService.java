package com.example.jwt.domain.user;

import com.example.jwt.core.generic.ExtendedService;
import java.util.UUID;
import org.springframework.security.core.userdetails.UserDetailsService;

public interface UserService extends UserDetailsService, ExtendedService<User> {

  User register(User user);

  User assignModule(UUID id, UUID moduleId);

  User unassignModule(UUID id, UUID moduleId);
}
