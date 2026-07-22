<?php

namespace App\Entity;

use Doctrine\ORM\Mapping as ORM;

// Minimal entity mapped to the shared `users` table (id / name / email),
// matching the Doppar and Laravel schemas for a like-for-like PK lookup.
#[ORM\Entity]
#[ORM\Table(name: 'users')]
class User
{
    #[ORM\Id]
    #[ORM\GeneratedValue]
    #[ORM\Column]
    public ?int $id = null;

    #[ORM\Column(length: 255)]
    public string $name = '';

    #[ORM\Column(length: 255)]
    public string $email = '';
}
