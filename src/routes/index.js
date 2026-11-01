import express from 'express';
import standRoute from './stand.js';

const router = express.Router();

// Временная заглушка, тк авторизации пока нет
const authMiddleware = (req, res, next) => next();

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