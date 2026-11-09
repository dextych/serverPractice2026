export class AppError extends Error {
    constructor(message, code = 'INTERNAL_ERR', statusCode = 500) {
        super(message);
        this.code = code;
        this.statusCode = statusCode;
        this.isOperational = true;
        
        Error.captureStackTrace(this, this.constructor);
    }
}