import { AppError } from './appError.js';

export const errorHandler = (err, req, res, next) => {
    console.error('Error:', {
        message: err.message,
        code: err.code,
        stack: err.stack,
        path: req.path,
        method: req.method
    });

    if (err instanceof AppError) {
        return res.status(err.statusCode).json({
            success: false,
            error: {
                message: err.message,
                code: err.code
            }
        });
    }

    if (err.name === 'SequelizeValidationError') {
        return res.status(400).json({
            success: false,
            error: {
                message: err.errors.map(e => e.message).join(', '),
                code: 'VALID_ERR'
            }
        });
    }

    if (err.name === 'SequelizeUniqueConstraintError') {
        return res.status(409).json({
            success: false,
            error: {
                message: 'Запись уже существует',
                code: 'CONFLICT'
            }
        });
    }

    return res.status(500).json({
        success: false,
        error: {
            message: 'Внутренняя ошибка сервера',
            code: 'INTERNAL_ERR'
        }
    });
};