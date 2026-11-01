import db from '../models/index.js';
import { Op, QueryTypes, Sequelize } from 'sequelize';

export default db;

export async function executeInTransaction(callback) {
    const transaction = await db.sequelize.transaction();
    try {
        const result = await callback(transaction);
        await transaction.commit();
    } catch(err) {
        await transaction.rollback();
        throw err;
    }
}
