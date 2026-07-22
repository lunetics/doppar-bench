<?php

namespace App\Controller;

use App\Entity\User;
use Doctrine\ORM\EntityManagerInterface;
use Symfony\Bundle\FrameworkBundle\Controller\AbstractController;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\Routing\Attribute\Route;

class BenchController extends AbstractController
{
    // Framework-overhead floor: static JSON, no database.
    #[Route('/json', name: 'bench_json', methods: ['GET'])]
    public function staticJson(): JsonResponse
    {
        return new JsonResponse([
            'framework' => 'symfony',
            'endpoint'  => 'json',
            'ok'        => true,
            'items'     => [1, 2, 3],
        ]);
    }

    // Mirrors the vendor benchmark: a single primary-key lookup via Doctrine
    // ORM, returned as JSON. We map the entity to an array by hand rather than
    // pulling in symfony/serializer, so the DB endpoint measures the ORM round
    // trip and not a heavyweight serializer — the fair equivalent of the other
    // frameworks' model->toArray().
    #[Route('/db', name: 'bench_db', methods: ['GET'])]
    public function dbRow(EntityManagerInterface $em): JsonResponse
    {
        /** @var User|null $user */
        $user = $em->find(User::class, 1);

        return new JsonResponse([
            'id'    => $user?->id,
            'name'  => $user?->name,
            'email' => $user?->email,
        ]);
    }
}
