// src/infrastructure/middleware/auth.js
import { config } from '../../../config/config.js'
import { AppError } from '../errors/appError.js';

export const authMiddleware = (req, res, next) => {
    const authHeader = req.headers['authorization'];

    if (!authHeader) {
        return next(
            new AppError(
                'Заголовок Authorization отсутствует', 
                'UNAUTHORIZED', 
                401
            )
        );
    }

    const [scheme, token] = authHeader.split(' ');

    if (scheme !== 'Bearer' || !token) {
        return next(
            new AppError(
                'Неверный формат авторизации. Ожидается: Bearer <token>', 
                'INVALID_AUTH_FORMAT', 
                401
            )
        );
    }

    const expectedToken = config.apiKey;

    if (!expectedToken || token !== expectedToken) {
        return next(
            new AppError(
                'Недействительный API-токен', 
                'FORBIDDEN_TOKEN', 
                401
            )
        );
    }

    // Если токен верный, пропускаем запрос дальше к обработчику маршрута
    next();
};