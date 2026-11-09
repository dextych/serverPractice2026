import express from 'express';
import standRoute from './stand.js';
import { authMiddleware } from '../infrastructure/middleware/auth.js';

const router = express.Router();

const registerRoutes = (routes) => {
    routes.forEach(route => {
        const { path, verb, handler, authedOnly } = route;
        if (authedOnly) {
            router[verb](path, authMiddleware, handler);
        } else {
            router[verb](path, handler);
        }
    });
};

// Регистрируем роуты стенда
registerRoutes(standRoute);

export default router;